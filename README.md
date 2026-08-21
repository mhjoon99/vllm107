# vllm/ — 사내 GPU 서버용 vLLM 스택

LiteLLM 프록시 뒤에 붙는 vLLM 추론 서버.
**이 디렉터리만 통째로 복사하면 서버에서 그대로 뜨는 자립 구조**다.

> 서버 IP·계정·배포 경로 등 실제 값은 이 파일에 적지 않는다.
> 아래 `<서버IP>`, `<계정>`, `<배포경로>`를 사내 값으로 치환해 실행할 것 (내부 문서 참고).

## 환경

| 항목 | 값 |
|---|---|
| 대상 서버 | 사내 GPU 서버 (NVIDIA GB10, **aarch64**, 통합 메모리 128GB급) |
| 배포 위치 | `<배포경로>/vllm/` |
| 서빙 포트 | 본체 **53108** / 리랭커 **53109** / Muse **53110** → 각 컨테이너 8000 (vLLM 기본) |
| 모델 | 본체·리랭커는 10B 이하, HF 자동 다운로드 (`.env`의 `MODEL_ID`, `RERANK_MODEL_ID`) |
| | Muse-Glimmer-30B는 예외 — profile `muse`로 격리 ([아래](#muse-glimmer-30b-profile-muse)) |

> vLLM은 **1 프로세스 = 1 모델**이라 리랭커는 별도 컨테이너(`vllm-rerank`)로 뜬다.
> 두 서비스가 한 compose에 있으므로 `docker compose up -d` 한 번이면 둘 다 기동된다.
> 하나만 띄우려면 `docker compose up -d vllm` / `... vllm-rerank vllm-rerank-warmup`
> (단 `MODEL_ID`는 파일 전체 파싱 시 검사되므로 `.env`에 값이 있어야 한다).

> ⚠️ **공존 주의**: 같은 서버에 기존 vLLM 스택(별도 디렉터리·포트)이 운영 중이다.
> 그쪽 파일·컨테이너·이미지를 수정/중지/삭제하지 말 것.
> 메모리도 나눠 쓰므로 동시 기동 전 GPU 메모리 배분을 협의할 것 (`.env`의 `GPU_MEM_UTIL`).
> Muse-Glimmer-30B는 이 협의 없이는 켤 수 없다 — [해당 절](#muse-glimmer-30b-profile-muse) 참고.

## 배포 절차

```bash
# 0) [로컬] 디렉터리 전송
#    ⚠️ 로컬 디렉터리명(vllm107)과 서버 디렉터리명(vllm)이 다르다.
#       `scp -r vllm107 ...:<배포경로>/` 로 보내면 <배포경로>/vllm107/ 이 생겨버린다.
#    ⚠️ Windows에서 작업했다면 CRLF가 섞이지 않았는지 먼저 확인할 것 (아래 참고).
ssh <계정>@<서버IP> mkdir -p <배포경로>/vllm   # 최초 1회

# 권장: tar over ssh — 이름 변경·실행권한·부분전송을 한 번에 처리한다.
#      --strip-components=1 이 vllm107/ 접두를 떼어내 <배포경로>/vllm/ 안으로 푼다.
#      아카이브에 없는 서버 파일(.env, results/)은 건드리지 않는다.
cd <로컬 부모 디렉터리>
tar czf - vllm107 | ssh <계정>@<서버IP> \
  'tar xzf - -C <배포경로>/vllm --strip-components=1'

# scp만 쓴다면 — 디렉터리가 아니라 "내용"을 보낸다 (.env.example은 dotfile이라 따로 지정)
cd <로컬 부모 디렉터리>
scp -rp vllm107/* vllm107/.env.example <계정>@<서버IP>:<배포경로>/vllm/
ssh <계정>@<서버IP> 'chmod +x <배포경로>/vllm/scripts/*.sh'   # scp가 실행권한을 놓칠 때 대비

# 1) [서버] 최초 1회 — 검증본 이미지 고정 (기존에 쓰는 이미지의 태그 복사)
docker tag vllm/vllm-openai:nightly vllm-openai:gb10-verified

# 2) [서버] 환경변수 작성
cd <배포경로>/vllm
cp .env.example .env
vi .env          # MODEL_ID 필수 기입

# 3) [서버] 기동 (첫 기동은 모델 다운로드로 수 분~수십 분)
docker compose up -d       # healthy 후 워밍업(vllm-warmup)까지 자동
docker compose ps          # vllm-srv가 healthy인지 확인
# (진행 로그 보기: docker compose logs -f)
```

## 동작 확인

```bash
# 서버에서
curl -s http://localhost:53108/v1/models

# 리랭커
curl -s http://localhost:53109/v1/rerank \
  -H 'Content-Type: application/json' \
  -d '{"model":"bge-reranker-v2-m3","query":"수도","documents":["서울은 한국의 수도","바나나는 노랗다"]}'
curl -s http://localhost:53108/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"vllm-srv","messages":[{"role":"user","content":"ping"}],"max_tokens":8}'
# ("vllm-srv"는 .env의 SERVED_NAME 값)

# Muse-Glimmer (profile muse로 띄운 경우에만)
curl -s http://localhost:53110/v1/models
curl -s http://localhost:53110/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"muse-glimmer-30b","messages":[{"role":"user","content":"ping"}],"max_tokens":8}'
# ("muse-glimmer-30b"은 .env의 MUSE_SERVED_NAME 값)

# 메모리 점유 확인 (통합 메모리 — nvidia-smi 대신 free 사용)
free -h
```

## LiteLLM 연동 (repo 쪽 작업)

`litellm/config.yaml`에 **새 엔트리 추가** (기존 vLLM 엔트리들은 별도 스택 소관 — 수정 금지):

```yaml
  - model_name: <외부 노출 이름>
    litellm_params:
      model: hosted_vllm/<SERVED_NAME 값>
      api_base: "http://<서버IP>:53108/v1"
      api_key: EMPTY

  # 리랭커 — rerank 모드는 LiteLLM이 경로(/v1/rerank)를 직접 붙이므로 api_base에 /v1 없이
  - model_name: vllm-bge-reranker-v2-m3
    litellm_params:
      model: hosted_vllm/<RERANK_SERVED_NAME 값>
      api_base: "http://<서버IP>:53109"
      api_key: EMPTY
    model_info:
      mode: rerank

  # Muse-Glimmer-30B — 멀티모달(image-text-to-text). 이미지 입력을 쓰려면
  # .env의 MUSE_MAX_IMAGES를 0에서 올려야 하고 MUSE_GPU_MEM_UTIL도 함께 올릴 것
  - model_name: vllm-muse-glimmer-30b
    litellm_params:
      model: hosted_vllm/<MUSE_SERVED_NAME 값>
      api_base: "http://<서버IP>:53110/v1"
      api_key: EMPTY
```

## 운영

```bash
docker compose up -d             # 기동 — healthy 후 워밍업까지 자동
docker compose ps                # 상태 (healthy 확인)
docker compose logs -f --tail 100
docker compose restart
docker compose down              # 중지 (이미지·HF 캐시는 유지 — 재기동 시 재다운로드 없음)

# 워밍업 결과 확인 (선택)
docker logs vllm-srv-warmup      # "warmup ok"면 정상

# [선택] R8 예산 검증 기록용 — 기동 + 대기 + KV캐시/메모리 지표 요약
bash scripts/up.sh
bash scripts/down.sh             # 중지 + 메모리 반납 확인
```

## Muse-Glimmer-30B (profile `muse`)

`meta-models/Muse-Glimmer-30B`를 **세 번째 서비스**(`vllm-muse`, 포트 **53110**)로 올리기 위한
구성. 본체·리랭커와 독립된 프로세스이며 **compose profile로 격리**돼 있어
`docker compose up -d`로는 뜨지 않는다 — `bash scripts/up_muse.sh`로만 기동한다.

### 왜 격리했나

> ⛔ **현재 이 서비스는 켤 수 없는 상태다.** 아래 두 조건이 모두 해결돼야 한다.
> `scripts/up_muse.sh`가 기동 전에 둘 다 검사하고, 실패하면 컨테이너를 띄우지 않는다.

**① 이미지가 아직 이 아키텍처를 모른다**

vLLM의 `muse_glimmer` 지원은 **2026-08-14**에 main에 들어갔다. 정식 릴리스
**v0.27.1(2026-08-11)에는 없다.** 지금 `vllm-openai:gb10-verified`가 그 이전
nightly에서 고정된 태그라면 `Unrecognized architecture ...`로 즉시 종료된다.

기존 검증본 태그는 **보존하고** 새 태그로 받아 검증할 것:

```bash
docker pull vllm/vllm-openai:nightly
docker tag vllm/vllm-openai:nightly vllm-openai:gb10-verified-2
# .env 에  VLLM_IMAGE=vllm-openai:gb10-verified-2
```

⚠️ `VLLM_IMAGE`는 본체·리랭커도 함께 쓰므로, 바꾸면 **세 서비스 모두** aarch64/GB10
재검증 대상이 된다. 이건 이 스택의 "검증본 이미지 고정" 원칙을 건드리는 변경이다.

**② 메모리 예산에 자리가 없다**

vLLM의 `--gpu-memory-utilization`은 각 프로세스가 **전체 통합 메모리 기준으로 독립
계산**한다. 합이 1.0을 넘으면 이 서비스뿐 아니라 **옆 스택까지 OOM**난다.

| 항목 | 현재 | 필요 |
|---|---|---|
| 옆 스택 (우리 소관 아님) | 0.70 | 협의 필요 |
| 본체 `GPU_MEM_UTIL` | 0.25 | |
| 리랭커 `RERANK_GPU_MEM_UTIL` | 0.05 | |
| Muse `MUSE_GPU_MEM_UTIL` | — | 0.22 |
| **합계** | **1.00 (이미 만차)** | **1.22 → 불가** |

→ 옆 스택이 얼마를 반납할지 **협의가 선행돼야 한다.** 결과를 `.env`의
`NEIGHBOR_GPU_MEM_UTIL`에 기록하면 `up_muse.sh`가 합계 ≤ 0.90을 검사한다.
(예: 옆 0.40 + 본체 0.15 + 리랭커 0.05 + Muse 0.22 = 0.82 ✅)

### 모델 선택

| repo | 가중치 | 비고 |
|---|---|---|
| `meta-models/Muse-Glimmer-30B` (bf16 원본) | 59.5GB | **이 서버엔 불가** |
| `RedHatAI/Muse-Glimmer-30B-NVFP4` | 20.0GB | **기본값.** GB10은 Blackwell(sm_121)이라 NVFP4 네이티브 경로 |
| `RedHatAI/Muse-Glimmer-30B-INT4` | 19.5GB | NVFP4 커널 문제 시 폴백 (W4A16) |

KV 캐시는 의외로 싸다 — 52층 중 **39층이 sliding window 2048**이고 full attention은
13층뿐이며 KV head가 2개(head_dim 128)라, 8192 컨텍스트 × 4 동시 요청이면 1GB 미만이다.
메모리는 사실상 가중치(20GB) + 비전 인코더/활성값이 지배한다.

### 기동·중지

```bash
bash scripts/up_muse.sh      # 선검사(이미지 지원 + 메모리 예산) → 기동 → health 대기 → KV 실측 출력
bash scripts/down_muse.sh    # Muse만 중지 (본체·리랭커는 유지)

docker logs -f vllm-muse-srv         # 진행 로그
docker logs vllm-muse-srv-warmup     # "muse warmup ok"면 정상
```

첫 기동은 20GB 다운로드 + 30B 로딩이라 오래 걸린다(healthcheck `start_period` 30분).
기동 후 출력되는 `Available KV cache memory` / `Maximum concurrency`를 보고
`MUSE_GPU_MEM_UTIL`·`MUSE_MAX_NUM_SEQS`를 재조정할 것.

### 멀티모달

image-text-to-text 모델(비전 인코더 50층 포함)이다. 기본값 `MUSE_MAX_IMAGES=0`은
**텍스트 전용**으로 띄워 비전 경로의 메모리 프로파일링을 생략한다.
이미지 입력을 쓰려면 `MUSE_MAX_IMAGES`를 올리고 `MUSE_GPU_MEM_UTIL`도 함께 올려야 한다.

## 부하 테스트 (선택 — 연동 후 성능 튜닝용)

서버가 떠 있는 상태에서, 같은 이미지의 `vllm bench serve`로 처리량·TTFT를 측정한다.
`GPU_MEM_UTIL`·`MAX_NUM_SEQS`·`EXTRA_ARGS`(예: `--kv-cache-dtype fp8`) 변경 전후 비교에 사용.

```bash
bash scripts/download_dataset.sh          # 최초 1회: ShareGPT 데이터셋 (~640MB)
bash scripts/bench_sharegpt.sh 20 5 4     # 파이프라인 확인용 짧은 실행
bash scripts/bench_sharegpt.sh            # 본 측정 (300 prompts, 5 req/s, 동시 8)
bash scripts/bench_prefix.sh              # prefix caching 효과 측정
# 결과: results/bench_results.jsonl 에 누적 (metadata의 setup 값으로 회차 구분)
```

## 파일 안내

- `readme_deploy.md` — **서버(107) 기준 운영 가이드** (실제 IP·경로 포함 — git 추적 저장소에 넣지 말 것)
- `docker-compose.yml` — 서비스 정의 (vllm 본체 + vllm-rerank 리랭커 + 각 워밍업 + vllm-muse `profile: muse` + bench 벤치마크 클라이언트)
- `.env.example` — 환경변수 샘플. `.env`는 서버에서만 생성, git 추적 금지
- `scripts/` — 서버에서 실행하는 운영 스크립트 (일상 기동/중지는 `docker compose up -d`/`down`으로 충분)
  - `up.sh` [선택] 기동+대기+메모리 지표 요약 / `down.sh` [선택] 중지+메모리 반납 확인
  - `up_muse.sh` **Muse-Glimmer 전용 기동** (이미지 지원·메모리 예산 선검사 포함 — 이 스크립트로만 기동) / `down_muse.sh` Muse만 중지
  - `download_dataset.sh` + `bench_sharegpt.sh` / `bench_prefix.sh` 부하 테스트
- `results/` — 벤치 결과 누적 (서버에서 생성됨)
