# 5단계: ArgoCD로 GitOps

GitOps: "클러스터에 무엇이 떠 있어야 하는가"를 Git에 적어 두고, 클러스터 안의 도구(ArgoCD)가 Git과 클러스터를 계속 비교해 맞추는 방식.
사람이나 CI가 `kubectl apply`로 클러스터를 직접 바꾸지 않는다. 바꾸고 싶으면 Git을 바꾼다.

## 전체 흐름

```
개발자: coupon-system에 push
  │
  ▼ GitHub Actions (coupon-system/.github/workflows/ci.yml)
  test   : 테스트 (MySQL·Redis·Kafka는 docker compose)
  image  : ARM64 이미지 → ghcr.io/diz99-art/coupon-system:<커밋 해시>
  deploy : platform-infra를 deploy key로 체크아웃 → k8s/apps/coupon/kustomization.yaml의 newTag를 커밋 해시로 → push
  │
  ▼ platform-infra main (Git = 원하는 상태)
  │
  ▼ ArgoCD (platform 네임스페이스, 60초 + 0~10초마다 Git 확인)
  Application coupon: Git(k8s/apps/coupon)을 kustomize build → 클러스터와 비교 → 다르면 적용(sync)
  │
  ▼ apps 네임스페이스: Deployment coupon 롤링 업데이트 (maxSurge 1, maxUnavailable 0)
```

## 역할 분리

- **Ansible** (`ansible/*.yml`): 맥에서 사람이 실행한다
  - VM 안 설정, k3s 설치 (`site.yml`)
  - 데이터 계층: MySQL·Redis·Kafka와 그 PV (`mysql.yml`, `redis.yml`, `kafka.yml`)
  - **Secret**: vault 값으로 만든다 (`mysql.yml`, `redis.yml`). Git에는 없다
  - ArgoCD 자체와 시작점(AppProject, 루트 Application) (`argocd.yml`)
- **ArgoCD**: 사람 손 없이 Git을 따라간다
  - 앱 배포: `k8s/apps/<앱>/` (지금은 coupon)
  - 어떤 앱을 올릴지: `k8s/argocd/apps/<앱>.yaml`
- 경계를 지키는 장치: AppProject `apps`가 `apps` 네임스페이스만, 클러스터 전체 객체 금지, **Secret 금지**.
  Git에 Secret을 실수로 넣어도 ArgoCD가 배포를 거부한다.

이유: 데이터 계층은 노드 디렉터리, PV, DB 계정처럼 "한 번 만들고 거의 안 바뀌며 순서가 중요한" 일이라 절차형(Ansible)이 맞다.
앱은 하루에도 여러 번 바뀌고 "지금 Git 상태와 같은가"만 중요하므로 선언형 동기화(ArgoCD)가 맞다.
Secret을 Git에 두려면 Sealed Secrets·External Secrets 같은 도구가 필요하다 → Vault 단계에서 다룬다.

## 1. ArgoCD 설치 (`ansible/roles/argocd`, Helm 차트 argo/argo-cd 10.10.5 = ArgoCD v3.5.5)

### 켜는 것

- **application-controller**: Git의 원하는 상태와 클러스터의 실제 상태를 비교하고 맞추는 본체
- **repo-server**: Git을 받아 `kustomize build`로 매니페스트를 만든다
- **server**: 웹 화면과 API (`http://<노드 IP>/argocd/`)
- **redis**: 위 셋이 공유하는 캐시 (렌더링 결과, 앱 상태). 없으면 매번 Git과 클러스터를 다시 읽는다

### 끄는 것과 이유

- **Dex** (`dex.enabled: false`): GitHub·Google 로그인(SSO)을 붙이는 구성요소. 관리자 계정 하나로 충분하다
- **notifications-controller** (`notifications.enabled: false`): 배포 결과를 Slack 등으로 보낸다. 보낼 곳이 없다
- **applicationset-controller** (`applicationSet.replicas: 0`): 템플릿 하나로 Application 여러 개를 찍어낸다. 앱이 적어서 Application YAML을 직접 쓴다
- **redis-ha**: Redis 3대 복제. 단일 노드 학습용이라 1대
- 동시 처리 수 축소: `controller.status.processors 5`(기본 20), `controller.operation.processors 2`(기본 10), `reposerver.parallelism.limit 2`

### 화면 접속과 로그인

- Ingress `/argocd` → `argocd-server` (`server.rootpath: /argocd`, `server.insecure: true` = Traefik 앞에서 HTTP)
  - 쿠폰 서버가 `/`를 쓰므로 경로로 나눴다. Traefik은 더 긴 경로(`/argocd`)를 먼저 맞춘다
- 관리자: `admin` / 비밀번호는 vault (`ansible-vault view group_vars/all/vault.yml`의 `vault_argocd_admin_password`)
  - Helm 값에는 bcrypt 해시만 넣는다. 해시를 vault에 **한 번 만들어 고정**한 이유: bcrypt는 소금값(salt)이 무작위라 실행할 때마다 만들면 해시가 달라져 Helm 릴리스가 매번 바뀐다(멱등성이 깨짐)
  - 해시를 주면 ArgoCD가 무작위 초기 비밀번호(`argocd-initial-admin-secret`)를 만들지 않는다

## 2. 매니페스트 구조: Kustomize

```
k8s/
├── apps/coupon/               ArgoCD Application "coupon"이 보는 폴더
│   ├── kustomization.yaml     resources 목록, configMapGenerator, images.newTag (CI가 바꾸는 유일한 줄)
│   ├── config.env             설정 (ConfigMap이 됨)
│   ├── deployment.yaml
│   ├── service.yaml
│   ├── pdb.yaml
│   └── ingress.yaml
└── argocd/apps/
    └── coupon.yaml            Application 정의 (루트 Application "platform-apps"가 이 폴더를 본다)
```

### Helm이 아니라 Kustomize를 고른 이유

- **평범한 YAML 그대로**: 템플릿 문법(`{{ }}`, if, range)이 없다. `kubectl kustomize k8s/apps/coupon`의 결과가 파일 내용과 거의 같아서 처음 보는 사람도 읽힌다
- **CI가 바꿀 곳이 한 줄**: `images.newTag`. Helm이라면 values 파일의 태그를 바꾸는데 결과는 같지만, 차트(templates/, Chart.yaml, values.yaml)를 따로 만들어야 한다
- **kubectl과 ArgoCD에 내장**: 따로 설치할 것이 없다
- **configMapGenerator**: 설정 내용의 해시가 ConfigMap 이름에 붙어(`coupon-config-c5h7m8k6k2`), 설정만 바꿔도 파드가 새로 뜬다. 4단계에서 손으로 만든 config-hash 어노테이션이 필요 없어졌다
- Helm이 나은 경우: 여러 팀이 같은 차트를 값만 바꿔 재사용하거나(ArgoCD 자체처럼), 남이 만든 소프트웨어를 설치할 때. 그래서 **ArgoCD는 Helm 차트로 설치**하고, **우리 앱은 Kustomize**로 쓴다
- 플랫폼 서비스 3개가 생기면 `k8s/apps/base`(공통 Deployment 모양) + 서비스별 overlay로 중복을 줄일 수 있다

### 넘겨받기 (Ansible → ArgoCD)

- 4단계의 Ansible `coupon` 롤과 `coupon.yml`을 지우고 같은 이름의 객체(Deployment, Service, PDB, Ingress)를 ArgoCD가 넘겨받았다
- `kubectl diff -k k8s/apps/coupon`으로 미리 비교: 바뀌는 건 ConfigMap 이름(해시)뿐 → 넘겨받을 때 롤링 업데이트 한 번
- Ansible이 만든 옛 ConfigMap `coupon-config`는 아무도 쓰지 않아 직접 지웠다 (ArgoCD는 자기가 만들지 않은 객체는 지우지 않는다)

## 3. 자동 배포 흐름과 권한

### deploy key를 고른 이유

CI(coupon-system)가 다른 저장소(platform-infra)에 push하려면 쓰기 권한이 필요하다. 기본 `GITHUB_TOKEN`은 자기 저장소에만 쓸 수 있다.

- **deploy key (선택)**: 저장소 하나에 붙는 SSH 키. platform-infra에만 쓸 수 있고, 만료가 없고, 사람 계정과 무관하다
- fine-grained PAT: 저장소·권한을 고를 수 있지만 사람 계정에 묶이고 만료(최대 1년)가 있어 갱신해야 한다
- classic PAT: 그 사람의 모든 저장소에 쓸 수 있어 너무 넓다
- GitHub App: 가장 정석(짧게 사는 토큰, 세밀한 권한)이지만 앱 등록·설치·키 관리가 필요해 지금 규모에는 과하다

### 설정한 것 (gh CLI로 했다. 웹에서 하려면 아래 경로)

1. 키 만들기: `ssh-keygen -t ed25519 -N "" -f key`
2. 공개키를 platform-infra에 쓰기 권한으로 등록
   - CLI: `gh repo deploy-key add key.pub -R diz99-art/platform-infra --allow-write --title "coupon-system CI"`
   - 웹: platform-infra → Settings → Deploy keys → Add deploy key → "Allow write access" 체크
3. 개인키를 coupon-system의 Actions Secret으로
   - CLI: `gh secret set PLATFORM_INFRA_DEPLOY_KEY -R diz99-art/coupon-system < key`
   - 웹: coupon-system → Settings → Secrets and variables → Actions → New repository secret
4. 맥에 남은 개인키 삭제 (GitHub Secret에만 있다. 잃어버리면 새로 만들어 1~3을 다시 하면 된다)

키를 바꾸고 싶을 때(유출 의심 등): platform-infra의 Deploy keys에서 지우고 1~4를 다시 한다.

### deploy job (`coupon-system/.github/workflows/ci.yml`)

- `needs: image` → 테스트와 이미지가 성공해야만 태그를 바꾼다
- `sed`로 `newTag:` 줄 하나만 바꾸고, 바뀌었는지 `grep`으로 확인
- 커밋 작성자는 `github-actions[bot]`, 메시지에 coupon-system 커밋 해시와 제목
- `concurrency: platform-infra-deploy`: 연달아 push해도 차례로. 그래도 push가 거절되면 `git pull --rebase` 후 최대 3번 재시도
- platform-infra에는 워크플로가 없어서 봇 커밋이 다시 CI를 부르는 반복이 없다

### ArgoCD가 변경을 아는 방법

- 60초(+0~10초)마다 Git을 확인한다 (`timeout.reconciliation`). 기본 120초(+0~60초)에서 줄였다
- 더 빠른 방법은 GitHub webhook(push 즉시 알림)이지만, 클러스터가 맥 안의 사설망(NAT 뒤)이라 GitHub가 접속할 수 없다
- 급하면 화면의 "Refresh" 또는 `kubectl -n platform annotate application coupon argocd.argoproj.io/refresh=normal`

## 4. 검증 기록 (2026-10-20)

### 설치

- `ansible-playbook argocd.yml`: 44초. 파드 4개(controller, repo-server, server, redis), ApplicationSet 0개
- 루트 Application이 Git의 `k8s/argocd/apps/coupon.yaml`을 읽어 `coupon` Application을 만들고, 기존 쿠폰 서버를 넘겨받아 Synced·Healthy
- 맥 브라우저 `http://192.168.252.2/argocd/` 200, vault 비밀번호로 로그인(API `/argocd/api/v1/session`에서 토큰 받음)
- 다시 실행: changed=0 (bcrypt 해시를 고정했기 때문)

### 사람 손 없이 배포 (push → 새 파드 2대 Ready)

1차 (워크플로 변경 커밋 `14b7c72`, 앱 코드는 그대로):
- test 2분 13초 → image 20초(캐시) → deploy 8초 → ArgoCD 감지 52초 → 롤링 업데이트 35초
- **합계 4분 32초**

2차 (코드 변경 `3ccc3e7`: Swagger의 발급 API 설명에 한 문장 추가):
- test 2분 52초 → image 1분 13초(앱 코드 층을 다시 빌드) → deploy 8초 → ArgoCD 감지 7초 → 롤링 업데이트 61초
- **합계 5분 34초**. 배포 뒤 `/v3/api-docs`에 새 문장 확인
- **배포 중 발급 부하**: push 150초 뒤부터 4분간 4개 연결로 계속 발급 → **101,923건 전부 202, 실패 0**
  - MySQL 101,923건 = Redis 카운터 101,923, 파드 재시작 0
- 가장 오래 걸리는 건 테스트(약 2~3분). ArgoCD 감지는 확인 주기에 따라 0~70초로 들쭉날쭉하다

### self-heal (kubectl로 클러스터를 직접 바꿈)

- `kubectl scale deploy coupon --replicas=1` → **0.85초** 뒤 ArgoCD가 2로 되돌림. 그 사이 파드 하나가 이미 종료돼 2대 Ready까지는 11초
- `kubectl delete svc coupon` → **0.7초** 뒤 다시 생성, 1초 뒤 Ingress로 API 200
- ArgoCD는 클러스터 변경을 지켜보다가(watch) Git과 달라지면 바로 되돌린다. Git 확인 주기(60초)와는 별개

### 롤백 (Git을 되돌림)

- platform-infra에서 봇의 태그 커밋 `e4e2ddd`를 `git revert` → push (+ 화면의 Refresh와 같은 `argocd.argoproj.io/refresh` 어노테이션)
- 4초 뒤 Deployment가 이전 태그 `14b7c72`로, **40초**에 롤백 끝. Swagger 설명이 옛 문장으로 돌아감
- 롤백 중 발급 **58,965건 전부 202**
- 다시 롤포워드(롤백 커밋을 revert): refresh 없이 11초 뒤 감지, 32초에 끝
- ArgoCD 화면의 "Rollback" 버튼은 자동 동기화가 켜져 있으면 쓸 수 없다(곧 Git 상태로 다시 덮어쓰므로). GitOps에서 롤백은 **Git 되돌리기**가 정석이고, 기록도 Git에 남는다

### 기타

- `site/mysql/redis/kafka/argocd.yml` 모두 다시 실행 changed=0

## 5. 메모리

- ArgoCD 실측(cgroup anon): controller 161Mi, repo-server 28Mi, server 22Mi, redis 4Mi = **215Mi** (limit 합 704Mi, 예산 600MB)
  - repo-server는 렌더링(kustomize build)할 때 잠깐 늘어나므로 limit을 여유 있게 둔다
- 같은 때 쿠폰 서버 361·516Mi / 640Mi (16만 건 부하 뒤 한 대가 81%), Kafka 483Mi / 768Mi
- 자세한 예산: [memory-plan.md](memory-plan.md)

## 운영 명령

```bash
kubectl -n platform get applications                           # 동기화 상태
kubectl -n platform annotate application coupon argocd.argoproj.io/refresh=normal --overwrite   # 지금 Git 확인
# 롤백: platform-infra에서
git revert <봇의 태그 커밋> && git push
# 새 앱 추가: k8s/apps/<앱>/ (Kustomize) + k8s/argocd/apps/<앱>.yaml (Application, project: apps) → push
```
