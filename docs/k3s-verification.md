# 2단계 검증 기록 (2026-10-20)

환경: 맥 M2 Pro 16GB, VM 3대 (cp1 2GB, worker1·2 3GB), Ubuntu 24.04.5, k3s v1.36.5+k3s1, ansible-core 2.21.5

## 1. 멱등성: 같은 플레이북을 두 번 실행

첫 실행 (빈 VM에 설치), 49초:

```
cp1      : ok=24  changed=11  unreachable=0  failed=0  skipped=2
worker1  : ok=20  changed=9   unreachable=0  failed=0  skipped=2
worker2  : ok=20  changed=9   unreachable=0  failed=0  skipped=2
```

첫 실행에서 changed가 된 작업:
- common: 패키지 업그레이드, 커널 모듈 설정 파일과 로드, sysctl 5개
- k3s_server: 설정 디렉터리, 설정 파일, 설치 스크립트 내려받기, k3s 설치, 맥 ~/.kube 디렉터리와 kubeconfig
- k3s_agent: 설정 디렉터리, 설정 파일, 설치 스크립트 내려받기, k3s 에이전트 설치
- 시간대와 스왑은 1단계 cloud-init이 이미 해둬서 changed가 아니었다 (스왑 끄기는 skipped: 스왑이 0MB라는 팩트를 보고 건너뜀)

바로 두 번째 실행, 15초:

```
cp1      : ok=22  changed=0  unreachable=0  failed=0  skipped=3
worker1  : ok=18  changed=0  unreachable=0  failed=0  skipped=3
worker2  : ok=18  changed=0  unreachable=0  failed=0  skipped=3
```

changed=0 → 이미 원하는 상태면 아무것도 바꾸지 않는다. skipped가 늘어난 것은 "k3s 설치"가 버전이 같아서 건너뛰었기 때문이다.
(최종본에서는 설치 스크립트 내려받기도 건너뛰어 skipped=4)

## 2. 드리프트 복구: 누가 손으로 설정을 바꿨을 때

worker2의 `/etc/rancher/k3s/config.yaml`에 한 줄을 직접 추가한 뒤 `site.yml`을 실행했다.
- worker2의 "k3s 에이전트 설정 파일"만 changed → 템플릿 내용으로 되돌아감
- 핸들러 `restart k3s-agent`가 worker2에서만 실행 (서비스 시작 시각 10:51:53 → 10:53:11)
- cp1, worker1은 changed=0, 재시작 없음

## 2-1. 미리 보기 (--check --diff)

`ansible-playbook site.yml --check --diff`: 16초, 3대 모두 changed=0 (실제로는 아무것도 바꾸지 않는다)

처음에는 check 모드에서 멈췄다. 고친 내용은 README 트러블슈팅에 있다.

## 3. 맥에서 kubectl

```
NAME      STATUS   ROLES           VERSION        INTERNAL-IP
cp1       Ready    control-plane   v1.36.5+k3s1   192.168.252.2
worker1   Ready    <none>          v1.36.5+k3s1   192.168.252.3
worker2   Ready    <none>          v1.36.5+k3s1   192.168.252.4
```

- kubectl v1.37.1 (Homebrew), kubeconfig `~/.kube/platform-infra.yaml`, 컨텍스트 `platform-infra`
- cp1 Taints: `node-role.kubernetes.io/control-plane:NoSchedule`

## 4. 동작 확인 (k8s/examples/nginx-demo.yaml)

- 배치: replicas 3 → worker1에 2개, worker2에 1개, cp1에 0개 (taint 동작)
- Ingress: 맥에서 `http://192.168.252.2/`, `.3`, `.4` 모두 HTTP 200 "Welcome to nginx!" (ServiceLB가 모든 노드에 80번 포트를 연다)
- 자가 치유: 파드 하나를 지우자 같은 순간 ReplicaSet이 새 파드를 만들고(SuccessfulCreate) 약 1초 뒤 컨테이너가 시작됐다.
  새 파드도 worker1에 배치. 이미지가 노드에 있어서 내려받는 시간이 없었다.
- 확인 후 `kubectl delete -f`로 정리 (demo 네임스페이스까지 삭제)

## 5. 제거 → 재설치

```bash
cd ansible
ansible-playbook k3s-uninstall.yml -e confirm=yes   # 6초
ansible-playbook site.yml                           # 29초 (노드 3대 Ready까지 포함)
```

- 제거 후 확인: `/usr/local/bin/k3s`, `/etc/rancher` 없음, k3s 서비스 inactive, 맥의 kubeconfig 삭제
- 제거 플레이북을 한 번 더 실행: changed=0 (이미 지워졌으면 건너뜀)
- 재설치 플레이북 끝 → Traefik이 80번 포트에 응답(404)할 때까지 약 35초 더 걸림 (Helm으로 Traefik을 설치하는 작업이 돌기 때문)
- **제거 시작부터 브라우저 접속 가능한 상태까지 전체 70초**
- 재설치 직후 다시 실행: 3대 모두 changed=0
- 시간 변화: 처음 측정은 제거 7초 + 플레이북 40초. 불필요한 핸들러 재시작을 없앤 뒤 31초, 설치 스크립트를 필요할 때만 받게 한 최종본은 29초
- 재설치한 클러스터에서 nginx 예제를 다시 띄워 HTTP 200 확인

## 6. 메모리 (설치 직후, 앱 없음, kubectl top nodes)

- cp1: `kubectl top` 925~1345Mi로 들쭉날쭉. VM 안 `free -m`으로 보면 used 1216MB, available 738MB
  - 프로세스별(RSS): k3s-server 약 980MB, containerd 약 195MB, metrics-server 64MB, coredns 57MB, local-path-provisioner 37MB
  - k3s-server 하나에 API 서버·스케줄러·컨트롤러·내장 DB(SQLite)·kubelet이 다 들어 있어서 크다
- worker1: 약 365Mi, worker2: 약 365~420Mi (Traefik이 뜬 노드가 조금 더 씀)
- 메모리 계획에서 cp1 여유를 850MB로 잡았지만 실제는 약 740MB → 계획을 고쳤다 (docs/memory-plan.md)
- `kubectl top`은 짧은 시간 평균이고 캐시 일부를 포함해 값이 흔들린다. 노드의 실제 여유는 `free -m`의 available을 본다
