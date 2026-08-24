# vLLM 스택 — GB10 서버(192.168.40.107) 운영 가이드

LiteLLM 프록시 뒤에 붙는 vLLM 추론 서버. 모델 3개를 각각 별도 컨테이너로 서빙한다.

> ⚠️ 이 파일에는 사내 IP·계정·경로가 들어 있고, 이 저장소는 GitHub(origin)에 푸시된다.
> 저장소를 public으로 두지 말 것. 배경은 맨 아래 [부록](#부록--이-문서와-git) 참고.

## 환경

| 항목 | 값 |
|---|---|
| 서버 | 192.168.40.107 (NVIDIA GB10, **aarch64**, 통합 메모리 128GB급 / `free` 기준 121Gi) |
| 접속 | `ssh mpiuser@192.168.40.107` |
| 스택 위치 | `/home/mpiuser/srv/vllm/` |
| 게이트웨이 | LiteLLM(.101)이 아래 포트로 접근 |

### 서비스 3개

vLLM은 **1 프로세스 = 1 모델**이다. 그래서 모델마다 compose 서비스가 따로 있고
`.env` 변수 세트도 따로다 — `MODEL_ID` 하나에 여러 모델을 적을 수는 없다.

| 서비스 | 모델 변수 | 컨테이너 | 포트 | 기동 |
|---|---|---|---|---|
| `vllm` (본체) | `MODEL_ID` | `${CONTAINER_NAME}` | **53108** | `docker compose up -d` |
| `vllm-rerank` | `RERANK_MODEL_ID` | `${RERANK_CONTAINER_NAME}` | **53109** | 〃 (같이 뜸) |
| `vllm-muse` | `MUSE_MODEL_ID` | `${MUSE_CONTAINER_NAME}` | **53107** | `docker compose --profile muse up -d` |

각 서비스에는 `*-warmup` 컨테이너가 딸려 있다. 본 서버가 healthy가 되면 1회 요청을
보내고 종료해서, 첫 실요청이 커널 JIT/CUDA graph 캡처 비용을 물지 않게 한다.

> ℹ️ **구 :53107 스택은 2026-08 철거됐다.** 포트 53107은 회수해 Muse-Glimmer가 쓴다.
> 다시 올라오면 `.env`의 `NEIGHBOR_GPU_MEM_UTIL`에 그쪽 실제 값을 적어야 예산 검사가 맞는다.

## 서버에 올리는 파일

**세 개뿐이다.** 셸 스크립트는 서버에 두지 않는다 — 예전에 스크립트가 하던 선검사는
compose의 `muse-preflight` 서비스로 옮겨져서 `docker compose up`만으로 실행된다.

```
docker-compose.yml    서비스 정의 + Muse 선검사
.env.example          환경변수 샘플 → 서버에서 cp .env.example .env
README.md             이 문서
```

`.env`는 **서버에서만 생성·관리**한다 (git·로컬 미러에 두지 않음).

### 전송

```bash
# [로컬] 작업 PC에서
cd C:/Users/ez/dune/workspace/vllm107
scp docker-compose.yml .env.example README.md mpiuser@192.168.40.107:/home/mpiuser/srv/vllm/
```

⚠️ **Windows에서 작업했다면 줄바꿈을 확인할 것.** CRLF가 섞이면 compose가 YAML 파싱은
해도 컨테이너 안에서 도는 파이썬 선검사가 깨질 수 있다:

```bash
# [로컬] 확인 — 셋 다 0이 나와야 정상
for f in docker-compose.yml .env.example README.md; do
  printf '%s: ' "$f"; tr -dc '\015' < "$f" | wc -c
done
```

✋ **서버에서 파일 직접 수정 금지.** 이 디렉터리는 작업 PC의 로컬 미러와 1:1 동기화가
원칙이다. 수정은 로컬에서 하고 scp로 올린다. 유일한 예외는 `.env`.

## 최초 1회 설정

```bash
ssh mpiuser@192.168.40.107
cd /home/mpiuser/srv/vllm

# 1) 검증본 이미지 태그 고정 (기존 스택이 쓰는 nightly 이미지를 복사 태그)
docker tag vllm/vllm-openai:nightly vllm-openai:gb10-verified

# 2) 환경변수 작성 — MODEL_ID 필수
cp .env.example .env
vi .env
```

`.env`에서 반드시 채울 것:

| 변수 | 설명 |
|---|---|
| `MODEL_ID` | **필수.** 본체 모델의 HF repo ID (10B 이하) |
| `CONTAINER_NAME` | `docker ps`에서 알아보기 쉽게 모델명으로 (예: `vllm-qwen3-9b`) |

⚠️ `SERVED_NAME`은 **건드리지 말 것.** LiteLLM이 부르는 이름이라, 바꾸면
`litellm/config.yaml`의 `hosted_vllm/<이 값>`도 같이 고쳐야 게이트웨이가 모델을 찾는다.
`CONTAINER_NAME`은 `docker ps` 표시용이라 바꿔도 안전하다 (바꾸면 기존 컨테이너가
고아로 남으니 `docker compose up -d --remove-orphans`로 올릴 것).

## 일상 운영 — 본체 + 리랭커

```bash
cd /home/mpiuser/srv/vllm

docker compose up -d               # 기동 — healthy 후 워밍업까지 자동
docker compose ps                  # healthy 확인
docker compose logs -f --tail 100
docker compose restart
docker compose down                # 중지 (이미지·HF 캐시 유지 — 재기동 시 재다운로드 없음)
```

첫 기동은 모델 다운로드로 수 분~수십 분 걸린다.

```bash
# healthy가 될 때까지 대기 (스크립트 없이)
until curl -sf http://localhost:53108/health >/dev/null; do sleep 5; printf .; done; echo ' ready'

# 기동 후 메모리 실측 — MEM_UTIL 재조정 근거로 기록
docker logs vllm-main 2>&1 \
  | grep -E 'Model loading took|Available KV cache memory|GPU KV cache size|Maximum concurrency'
free -h
```

## Muse-Glimmer-30B — `docker compose --profile muse up -d`

```bash
cd /home/mpiuser/srv/vllm
docker compose --profile muse up -d
```

이 한 줄이 **선검사 → 기동 → 워밍업**을 순서대로 처리한다. 순서는 compose가 강제한다:

```
muse-preflight  ──(exit 0이어야만)──▶  vllm-muse  ──(healthy여야만)──▶  vllm-muse-warmup
   depends_on:                            depends_on:
   service_completed_successfully         service_healthy
```

선검사가 실패하면 `dependency failed to start`로 멈추고 **`vllm-muse`는 Created 상태로
남아 절대 시작되지 않는다.** 이유를 보려면:

```bash
docker compose --profile muse logs muse-preflight
```

### 선검사 3종

| # | 검사 | 실패하면 |
|---|---|---|
| 1 | 이미지가 `muse_glimmer` 아키텍처를 아는가 | `Unrecognized architecture`로 즉사할 상황을 미리 차단 |
| 2 | 설정값 예산 합 ≤ `MEM_BUDGET_CEILING` | 이론상 초과 — `.env` 조정 필요 |
| 3 | `/proc/meminfo` 실측 여유 ≥ 필요량 + `MEM_SAFETY_MARGIN_GB` | 지금 당장 자리가 없음 |

2번은 "이론상 안전한가", 3번은 "지금 실제로 뜰 자리가 있나"를 본다. 둘은 다르다 —
설정값이 그대로여도 다른 뭔가가 메모리를 먹고 있으면 3번에서 걸린다.

> ⚠️ **3번의 한계**: `docker compose --profile muse up -d`는 본체·리랭커와 Muse를
> 동시에 올릴 수 있다. 그러면 선검사가 본체 할당 **전에** 실측해서 낙관적으로 나온다.
> 이 경우를 덮는 게 2번(설정값 합계)이다. 둘을 같이 봐야 하는 이유다.

### ① 이미지 — 남은 유일한 블로커

vLLM의 `muse_glimmer` 지원은 **2026-08-14** main에 들어갔다. 정식 릴리스
**v0.27.1(2026-08-11)에는 없다.** `vllm-openai:gb10-verified`가 그 이전 nightly에서
고정된 태그라면 선검사 1번에서 걸린다. 직접 확인:

```bash
docker run --rm --entrypoint python3 vllm-openai:gb10-verified -c \
  "import vllm, importlib.util as u; print(vllm.__version__, \
   u.find_spec('vllm.model_executor.models.muse_glimmer') is not None)"
```

`True`가 아니면 **기존 검증본 태그는 그대로 두고** 새 태그로 받아 검증한다:

```bash
docker pull vllm/vllm-openai:nightly
docker tag vllm/vllm-openai:nightly vllm-openai:gb10-verified-2
vi .env      # VLLM_IMAGE=vllm-openai:gb10-verified-2
```

> ⚠️ `VLLM_IMAGE`는 본체·리랭커도 함께 쓴다. 바꾸면 **세 서비스 전부** aarch64/GB10
> 재검증 대상이 된다. "검증본 이미지 고정" 원칙을 건드리는 변경이니 혼자 결정하지 말 것.

### ② 통합 메모리 예산 (현재는 통과)

vLLM의 `--gpu-memory-utilization`은 컨테이너끼리 **공유되지 않는다.** 각 프로세스가
자기 값을 독립적으로 갖는다. 다만 **분모는 공유한다** — 셋 다 같은 121Gi를 기준으로
비율을 계산하므로, 합은 사람이 관리해야 한다.

또한 이 값은 **예약이 아니라 상한**이다. 생성 모델(본체·Muse)은 KV 캐시를 미리 잡아
예산을 실제로 채우지만, 리랭커는 **pooling 모델이라 KV 캐시가 없어** 가중치만 쓴다.
장부상 0.03이어도 실측은 ~1.5Gi다.

> ⚠️ **GB10은 CPU와 GPU가 같은 메모리를 쓴다.** 합이 1.0에 가까워지면 vLLM이 죽는 게
> 아니라 **OS의 OOM killer가 아무 프로세스나 잡아 서버 전체가 불안정해진다.**
> 데스크톱(Xorg/gnome-shell)까지 떠 있으므로 여유를 넉넉히 남긴다.

| 항목 | 설정값 | 실측(121Gi 기준) |
|---|---|---|
| 외부 스택 `NEIGHBOR_GPU_MEM_UTIL` | 0 (2026-08 철거) | — |
| 본체 `GPU_MEM_UTIL` | 0.25 | ~25Gi |
| 리랭커 `RERANK_GPU_MEM_UTIL` | 0.03 | ~1.5Gi (pooling — 예산을 채우지 않음) |
| Muse `MUSE_GPU_MEM_UTIL` | 0.22 | ~26.6Gi (예상) |
| **합계** | **0.50** | **~53Gi, 여유 ~68Gi** |

상한은 `.env`의 `MEM_BUDGET_CEILING`(기본 **0.80**). 121Gi 중 약 24Gi를 OS·페이지캐시·
로딩 중 스파이크용으로 남기는 값이다. 실측 검사의 여유분은 `MEM_SAFETY_MARGIN_GB`(기본 8).

### 모델 선택

| repo | 가중치 | 비고 |
|---|---|---|
| `meta-models/Muse-Glimmer-30B` (bf16 원본) | 59.5GB | **이 서버엔 불가** |
| `RedHatAI/Muse-Glimmer-30B-NVFP4` | 20.0GB | **기본값.** GB10은 Blackwell(sm_121)이라 NVFP4 네이티브 경로 |
| `RedHatAI/Muse-Glimmer-30B-INT4` | 19.5GB | NVFP4 커널 문제 시 폴백 (W4A16) |

KV 캐시는 의외로 싸다 — 52층 중 **39층이 sliding window 2048**이고 full attention은
13층뿐이며 KV head가 2개(head_dim 128)라, 8192 컨텍스트 × 4 동시 요청이면 1GB 미만이다.
메모리는 사실상 가중치(20GB) + 비전 인코더/활성값이 지배한다. 그래서
`MUSE_GPU_MEM_UTIL`을 올려도 동시 처리 수는 별로 늘지 않는다.

### 멀티모달

image-text-to-text 모델(비전 인코더 50층 포함)이다. 기본값 `MUSE_MAX_IMAGES=0`은
**텍스트 전용**으로 띄워 비전 경로의 메모리 프로파일링을 생략한다.
이미지 입력을 쓰려면 `MUSE_MAX_IMAGES`를 올리고 `MUSE_GPU_MEM_UTIL`도 함께 올려야 한다.

### 중지·상태

```bash
docker compose --profile muse rm -sf vllm-muse vllm-muse-warmup   # Muse만 중지
docker compose --profile muse ps                                  # 상태 (profile 없이는 안 보인다)
docker logs -f vllm-muse-glimmer-30b                              # 진행 로그
docker logs vllm-muse-glimmer-30b-warmup                          # "muse warmup ok"면 정상
free -h                                                           # 메모리 반납 확인
```

첫 기동은 20GB 다운로드 + 30B 로딩이라 오래 걸린다(healthcheck `start_period` 30분).
기동 후 로그의 `Available KV cache memory` / `Maximum concurrency`를 보고
`MUSE_GPU_MEM_UTIL`·`MUSE_MAX_NUM_SEQS`를 재조정할 것.

## 동작 확인

```bash
# 본체
curl -s http://localhost:53108/v1/models
curl -s http://localhost:53108/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"vllm-srv","messages":[{"role":"user","content":"ping"}],"max_tokens":8}'
# ("vllm-srv"는 .env의 SERVED_NAME 값)

# 리랭커 — relevance_score가 붙은 순위 배열이 오면 정상
curl -s http://localhost:53109/v1/rerank \
  -H 'Content-Type: application/json' \
  -d '{"model":"bge-reranker-v2-m3","query":"수도","documents":["서울은 한국의 수도","바나나는 노랗다"]}'

# Muse — profile muse로 띄운 경우에만
curl -s http://localhost:53107/v1/models
curl -s http://localhost:53107/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"muse-glimmer-30b","messages":[{"role":"user","content":"ping"}],"max_tokens":8}'

free -h    # 메모리 점유. GB10은 nvidia-smi가 GPU 메모리를 Not Supported로 보고하므로 free가 기준
```

## LiteLLM 연동 (.101, repo 쪽 작업)

`litellm/config.yaml`에 **새 엔트리 추가** (기존 vLLM 엔트리는 별도 스택 소관 — 수정 금지):

```yaml
  - model_name: <외부 노출 이름>
    litellm_params:
      model: hosted_vllm/<SERVED_NAME 값>
      api_base: "http://192.168.40.107:53108/v1"
      api_key: EMPTY

  # 리랭커 — rerank 모드는 LiteLLM이 경로(/v1/rerank)를 직접 붙이므로 api_base에 /v1 없이
  - model_name: vllm-bge-reranker-v2-m3
    litellm_params:
      model: hosted_vllm/<RERANK_SERVED_NAME 값>
      api_base: "http://192.168.40.107:53109"
      api_key: EMPTY
    model_info:
      mode: rerank

  # Muse-Glimmer-30B — 멀티모달(image-text-to-text)
  - model_name: vllm-muse-glimmer-30b
    litellm_params:
      model: hosted_vllm/<MUSE_SERVED_NAME 값>
      api_base: "http://192.168.40.107:53107/v1"
      api_key: EMPTY
```

## 서버 재부팅 후

**본체·리랭커**는 `restart: unless-stopped`라 스스로 다시 뜬다. 단 **워밍업은 자동으로
다시 돌지 않으므로** 첫 실요청이 느린 게 싫으면 한 번 실행:

```bash
docker start vllm-main-warmup && docker logs vllm-main-warmup    # "warmup ok" 확인
```

**Muse는 `restart: no`다** (`.env`의 `MUSE_RESTART`). 재부팅 후 자동으로 뜨지 않는다.
의도된 설계다 — `unless-stopped`면 도커 데몬이 `muse-preflight`를 **건너뛰고** 되살리는데,
그 사이 `.env` 배분이 바뀌었으면 부팅 직후 OOM이 난다. 다시 올릴 때는:

```bash
docker compose --profile muse up -d    # 선검사를 다시 거친다
```

## 부하 테스트 (선택)

`GPU_MEM_UTIL`·`MAX_NUM_SEQS`·`EXTRA_ARGS` 변경 전후 비교용.
**다른 서비스가 유휴일 때 돌릴 것** (통합 메모리·GPU를 공유하므로 수치가 흔들린다).

```bash
docker compose --profile bench run --rm bench \
  --backend openai-chat --host 192.168.40.107 --port 53108 \
  --endpoint /v1/chat/completions --model <MODEL_ID> \
  --served-model-name <SERVED_NAME> --dataset-name random --num-prompts 50
```

ShareGPT 데이터셋을 쓰려면 `.env`의 `DATASET_DIR`에 미리 받아둔 뒤
`--dataset-name sharegpt --dataset-path /data/ShareGPT_V3_unfiltered_cleaned_split.json`.

## 문제 해결

```bash
docker compose ps                                   # Muse는 --profile muse 를 붙여야 보인다
docker logs --tail 50 vllm-main                     # 본체 로그
docker logs --tail 50 vllm-muse-glimmer-30b         # Muse 로그
docker compose --profile muse logs muse-preflight   # 선검사가 왜 막았는지
curl -s http://localhost:53108/metrics | grep -E "e2e_request_latency|num_requests_waiting"
```

| 증상 | 원인 / 조치 |
|---|---|
| `dependency failed to start: container ...-preflight exited (1)` | 선검사가 막은 것. `logs muse-preflight`로 1/2/3 중 어느 항목인지 확인 |
| Muse가 `Unrecognized architecture`로 죽음 | 이미지가 2026-08-14 이전 nightly → [① 이미지](#-이미지--남은-유일한-블로커) |
| 컨테이너가 계속 재시작 | `docker logs`에서 OOM/모델 로드 실패 확인 → `.env`의 `GPU_MEM_UTIL`·`MEM_LIMIT` 조정 |
| 선검사 3번이 계속 거부 | `docker ps`·`free -h`로 뭐가 쓰는지 먼저 확인. `MEM_SAFETY_MARGIN_GB` 하향은 최후 수단 |
| 게이트웨이(.101) 응답이 느림 | 위 metrics로 서버측 지연인지 먼저 분리 |
| `docker compose up -d`에 Muse가 딸려 옴 | profile로 격리돼 있어 그럴 일은 없다. 단 `up -d vllm-muse`처럼 **서비스명을 직접 대면** profile이 자동 활성화된다 |

## 부록 — 이 문서와 git

원래 이 내용은 `README.md`(자리표시자)와 `readme_deploy.md`(실제 IP·계정)로 나뉘어
있었고, 후자에 "git 추적 저장소에 넣지 말 것"이라고 적혀 있었다. 그런데 실제로는
`readme_deploy.md`가 git에 추적되어 `d333fcc` 커밋으로 origin에 이미 올라가 있었다.
분리해도 보호 효과가 없었으므로 이 파일 하나로 합쳤다.

실제로 값을 감추려면 아래 중 하나가 필요하다 (파일 분리로는 안 된다):

- 저장소를 private으로 유지 — 지금 상태에서 가장 현실적
- 또는 IP·계정·경로를 자리표시자로 되돌리고 실제 값은 서버의 `.env`에만 두기.
  커밋 이력에 남은 값은 `git filter-repo` 등으로 별도 제거해야 한다
