# vLLM 스택 운영 가이드 — GB10 서버(192.168.40.107) 기준

이 문서는 **서버에 접속해서 작업하는 사람** 기준으로 쓴 운영 가이드다.
배포 절차 전반(로컬 PC에서의 복사 등)은 `README.md` 참고.

| 항목 | 값 |
|---|---|
| 서버 | 192.168.40.107 (NVIDIA GB10, aarch64, 통합 메모리 128GB급) |
| 접속 | `ssh mpiuser@192.168.40.107` |
| 스택 위치 | `/home/mpiuser/srv/vllm/` |
| 서빙 포트 | 본체 **53108** / 리랭커 **53109** / Muse **53110** → 각 컨테이너 8000 |
| 컨테이너 | `vllm-srv` (본체) / `vllm-rerank-srv` (리랭커) / `vllm-muse-srv` (Muse, profile `muse`) / `*-warmup` (워밍업, 1회성) |
| 게이트웨이 연동 | LiteLLM(.101)이 `http://192.168.40.107:53108/v1`, 리랭커는 `:53109`, Muse는 `:53110/v1` 로 접근 |

> vLLM은 **1 프로세스 = 1 모델**이라 리랭커(`bge-reranker-v2-m3`)는 별도 컨테이너로 뜬다.
> 같은 compose에 정의돼 있어 `docker compose up -d` 한 번이면 본체+리랭커가 함께 기동된다.
> Muse-Glimmer-30B(`vllm-muse-srv`)는 profile `muse`로 격리돼 있어 이 명령으로는 **뜨지 않는다** —
> `bash scripts/up_muse.sh`로만 기동한다. 아래 [Muse-Glimmer-30B](#muse-glimmer-30b-profile-muse) 절 참고.

> ⚠️ **공존 주의**: 이 서버에는 별도 vLLM 스택(**:53107**, 별도 디렉터리)이 함께 운영 중이다.
> 그쪽 파일·컨테이너·이미지를 수정/중지/삭제하지 말 것.
> 통합 메모리를 나눠 쓰므로 `.env`의 `GPU_MEM_UTIL`·`MEM_LIMIT` 변경 전에 배분을 협의할 것.
> **:53107 스택이 0.7을 쓰고 있어 현재 배분(0.7 + 본체 0.25 + 리랭커 0.05 = 1.00)에는
> Muse-Glimmer-30B가 들어갈 자리가 없다.** 반납 협의 없이는 켤 수 없다 (아래 절).

> ✋ **서버에서 파일 직접 수정 금지**: 이 디렉터리는 작업 PC의 로컬 미러와 1:1 동기화가 원칙이다.
> 수정은 로컬에서 하고 scp로 올린다. 서버에서만 고치면 다음 배포 때 덮어써진다.
> 유일한 예외는 `.env` (서버에서만 생성·관리, git/미러에 두지 않음).

## 최초 1회 설정

```bash
cd /home/mpiuser/srv/vllm

# 1) 검증본 이미지 태그 고정 (기존 스택이 쓰는 nightly 이미지를 복사 태그)
docker tag vllm/vllm-openai:nightly vllm-openai:gb10-verified

# 2) 환경변수 작성 — MODEL_ID 필수
cp .env.example .env
vi .env
```

## 일상 운영

```bash
cd /home/mpiuser/srv/vllm

docker compose up -d             # 기동 — healthy 후 워밍업(vllm-warmup)까지 자동
docker compose ps                # vllm-srv가 healthy인지 확인
docker compose logs -f --tail 100
docker compose restart
docker compose down              # 중지 (이미지·HF 캐시는 유지 — 재기동 시 재다운로드 없음)

docker logs vllm-srv-warmup      # 워밍업 확인 — "warmup ok"면 정상
```

첫 기동은 모델 다운로드로 수 분~수십 분 걸릴 수 있다 (`docker compose logs -f`로 진행 확인).

## 동작 확인

```bash
curl -s http://localhost:53108/v1/models

curl -s http://localhost:53108/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"vllm-srv","messages":[{"role":"user","content":"ping"}],"max_tokens":8}'
# ("vllm-srv"는 .env의 SERVED_NAME 값)

# 리랭커 — relevance_score가 붙은 순위 배열이 오면 정상
curl -s http://localhost:53109/v1/rerank \
  -H 'Content-Type: application/json' \
  -d '{"model":"bge-reranker-v2-m3","query":"수도","documents":["서울은 한국의 수도","바나나는 노랗다"]}'
docker logs vllm-rerank-srv-warmup   # "rerank warmup ok"면 정상

# Muse-Glimmer — profile muse로 띄운 경우에만
curl -s http://localhost:53110/v1/models
curl -s http://localhost:53110/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"muse-glimmer-30b","messages":[{"role":"user","content":"ping"}],"max_tokens":8}'
docker logs vllm-muse-srv-warmup     # "muse warmup ok"면 정상

free -h    # 메모리 점유 확인 (통합 메모리 — nvidia-smi 대신 free)
```

## Muse-Glimmer-30B (profile `muse`)

`meta-models/Muse-Glimmer-30B`를 세 번째 서비스 `vllm-muse-srv`(포트 **53110**)로 띄우는 절차.
본체·리랭커와 독립된 프로세스이며 **compose profile로 격리**돼 있다.

> ⛔ **현재 이 서비스는 켤 수 없는 상태다.** 아래 두 조건이 모두 해결돼야 한다.
> `scripts/up_muse.sh`가 기동 전에 둘 다 검사하고, 실패하면 컨테이너를 띄우지 않는다.
> `docker compose up -d`로는 뜨지 않으니 실수로 켜질 걱정은 없다.

### 기동 전 조건 ① — 이미지가 이 아키텍처를 알아야 한다

vLLM의 `muse_glimmer` 지원은 **2026-08-14** main에 들어갔다. 정식 릴리스
**v0.27.1(2026-08-11)에는 없다.** 지금 `vllm-openai:gb10-verified`가 그 이전 nightly에서
고정된 태그라면 `Unrecognized architecture MuseGlimmerForConditionalGeneration`로 즉시 죽는다.

서버에서 직접 확인:

```bash
docker run --rm --entrypoint python3 vllm-openai:gb10-verified -c \
  "import vllm, importlib.util as u; print(vllm.__version__, \
   u.find_spec('vllm.model_executor.models.muse_glimmer') is not None)"
```

`True`가 아니면 **기존 검증본 태그는 그대로 두고** 새 태그로 받아서 검증한다:

```bash
docker pull vllm/vllm-openai:nightly
docker tag vllm/vllm-openai:nightly vllm-openai:gb10-verified-2
vi .env      # VLLM_IMAGE=vllm-openai:gb10-verified-2
```

> ⚠️ `VLLM_IMAGE`는 본체·리랭커도 함께 쓴다. 바꾸면 **세 서비스 전부** aarch64/GB10
> 재검증 대상이 되고, :53107 스택이 쓰는 원본 이미지와도 버전이 갈린다.
> 이건 이 스택의 "검증본 이미지 고정" 원칙을 건드리는 변경이니 혼자 결정하지 말 것.

### 기동 전 조건 ② — 통합 메모리 예산에 자리가 있어야 한다

vLLM의 `--gpu-memory-utilization`은 각 프로세스가 **전체 통합 메모리(128GB) 기준으로 독립
계산**한다. 합이 1.0을 넘으면 이 서비스뿐 아니라 **:53107 스택까지 OOM**난다.

| 항목 | 현재 | Muse 추가 시 |
|---|---|---|
| :53107 스택 (우리 소관 아님) | 0.70 | 협의 필요 |
| 본체 `GPU_MEM_UTIL` | 0.25 | |
| 리랭커 `RERANK_GPU_MEM_UTIL` | 0.05 | |
| Muse `MUSE_GPU_MEM_UTIL` | — | 0.22 |
| **합계** | **1.00 (이미 만차)** | **1.22 → 불가** |

:53107 담당자와 반납 폭을 협의한 뒤, 결과를 `.env`의 `NEIGHBOR_GPU_MEM_UTIL`에 적는다.
`up_muse.sh`가 네 값의 합이 **0.90 이하**인지 검사하고, 넘으면 기동을 거부한다.

```
예) 옆 0.40 + 본체 0.15 + 리랭커 0.05 + Muse 0.22 = 0.82  ✅
```

### 기동·중지

```bash
cd /home/mpiuser/srv/vllm

bash scripts/up_muse.sh      # 선검사(①②) → 기동 → health 대기 → KV 실측 출력
bash scripts/down_muse.sh    # Muse만 중지 (본체·리랭커는 그대로)

docker logs -f vllm-muse-srv         # 진행 로그
docker logs vllm-muse-srv-warmup     # "muse warmup ok"면 정상
docker compose --profile muse ps     # 상태 (profile 없이는 muse가 안 보인다)
```

첫 기동은 양자화본 ~20GB 다운로드 + 30B 로딩이라 오래 걸린다
(healthcheck `start_period` 30분, `up_muse.sh` 대기 상한 1시간).
기동 후 출력되는 `Available KV cache memory` / `Maximum concurrency`를 보고
`.env`의 `MUSE_GPU_MEM_UTIL`·`MUSE_MAX_NUM_SEQS`를 재조정한다.

### 모델 선택

| repo | 가중치 | 비고 |
|---|---|---|
| `meta-models/Muse-Glimmer-30B` (bf16 원본) | 59.5GB | **이 서버엔 불가** |
| `RedHatAI/Muse-Glimmer-30B-NVFP4` | 20.0GB | **기본값.** GB10은 Blackwell(sm_121)이라 NVFP4 네이티브 경로 |
| `RedHatAI/Muse-Glimmer-30B-INT4` | 19.5GB | NVFP4 커널 문제 시 폴백 (W4A16) |

KV 캐시는 싸다 — 52층 중 39층이 sliding window 2048이고 full attention은 13층뿐이며
KV head가 2개(head_dim 128)라, 8192 컨텍스트 × 4 동시 요청이면 1GB 미만이다.
메모리는 사실상 가중치(20GB) + 비전 인코더/활성값이 지배한다.

### 멀티모달

image-text-to-text 모델(비전 인코더 50층 포함)이다. 기본값 `MUSE_MAX_IMAGES=0`은
**텍스트 전용**으로 띄워 비전 경로의 메모리 프로파일링을 생략한다.
이미지 입력을 쓰려면 `MUSE_MAX_IMAGES`를 올리고 `MUSE_GPU_MEM_UTIL`도 함께 올려야 한다.

## 서버 재부팅·컨테이너 자동 재시작 후

`vllm-srv`는 `restart: unless-stopped`라 재부팅 후 스스로 다시 뜬다.
단, **워밍업은 자동으로 다시 돌지 않으므로** 첫 실요청이 느린 게 싫으면 한 번 실행:

```bash
docker start vllm-srv-warmup     # 종료돼 있던 워밍업 컨테이너 재실행
docker logs vllm-srv-warmup      # "warmup ok" 확인
docker start vllm-muse-srv-warmup && docker logs vllm-muse-srv-warmup   # Muse를 쓰는 경우
```

> ⚠️ **Muse도 `restart: unless-stopped`다.** 한 번 띄운 뒤에는 재부팅 후
> `up_muse.sh`의 선검사를 거치지 않고 스스로 올라온다. 그 사이 `.env`의
> 메모리 값이나 :53107 스택의 배분이 바뀌었다면 재부팅 직후 OOM이 날 수 있다.
> 배분을 조정한 날에는 `bash scripts/down_muse.sh`로 내려두거나,
> 재부팅 후 `free -h`로 여유를 확인할 것.

## R8 예산 검증 기록 (선택)

KV캐시/메모리 지표를 계획서에 기록할 때만 사용:

```bash
bash scripts/up.sh               # 기동 + 대기 + 지표 요약 출력
bash scripts/down.sh             # 중지 + 메모리 반납 확인
```

## 부하 테스트 (선택)

서버가 떠 있는 상태에서 실행. `GPU_MEM_UTIL`·`MAX_NUM_SEQS`·`EXTRA_ARGS` 변경 전후 비교용.
**:53107 스택이 유휴일 때 돌릴 것** (통합 메모리·GPU를 공유하므로 수치가 흔들린다).

```bash
bash scripts/download_dataset.sh          # 최초 1회: ShareGPT 데이터셋 (~640MB)
bash scripts/bench_sharegpt.sh 20 5 4     # 파이프라인 확인용 짧은 실행
bash scripts/bench_sharegpt.sh            # 본 측정 (300 prompts, 5 req/s, 동시 8)
bash scripts/bench_prefix.sh              # prefix caching 효과 측정
# 결과: results/bench_results.jsonl 에 누적
```

## 문제 해결

```bash
docker compose ps                          # 상태 한눈에 (Muse는 --profile muse 를 붙여야 보인다)
docker logs --tail 50 vllm-srv             # 본체 로그
docker logs vllm-srv-warmup                # 워밍업 실패 여부
docker logs --tail 50 vllm-muse-srv        # Muse 로그 (아키텍처 미지원·OOM 확인)
curl -s http://localhost:53108/metrics | grep -E "e2e_request_latency|num_requests_waiting"
```

- 컨테이너가 계속 재시작되면: `docker logs vllm-srv`에서 OOM/모델 로드 실패 확인 → `.env`의 `GPU_MEM_UTIL`·`MEM_LIMIT` 조정
- Muse가 `Unrecognized architecture`로 죽으면: 이미지가 2026-08-14 이전 nightly다 → [기동 전 조건 ①](#기동-전-조건--이미지가-이-아키텍처를-알아야-한다)
- `up_muse.sh`가 예산 초과로 거부하면: 임의로 상한을 올리지 말고 :53107 담당자와 협의할 것 (`MEM_BUDGET_CEILING`은 최후 수단)
- 게이트웨이(.101)에서 응답이 느리면: 위 metrics로 서버측 지연인지 먼저 분리
