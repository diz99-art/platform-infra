# 2단계 설계: Ansible로 k3s 설치

## 플레이북 구조

```
ansible/
├── ansible.cfg            설정 (인벤토리 위치, 출력 형식)
├── inventory.ini          서버 목록과 그룹 (control_plane, workers, k3s_cluster)
├── requirements.yml       필요한 컬렉션 (community.general, ansible.posix, kubernetes.core, ansible.mysql)
├── group_vars/
│   └── all.yml            모든 서버 공통 변수: k3s 버전, 서버 IP, kubeconfig 위치
├── site.yml               설치 플레이북: common → k3s_server → k3s_agent 순서
├── k3s-uninstall.yml      제거 플레이북 (-e confirm=yes 필요)
└── roles/
    ├── common/            모든 노드: 패키지, 시간대, 스왑, 커널 모듈, sysctl
    │   ├── defaults/main.yml
    │   └── tasks/main.yml
    ├── k3s_server/        cp1: k3s 서버, 조인 토큰, 맥용 kubeconfig
    │   ├── defaults/main.yml   taint, 끌 구성요소
    │   ├── templates/config.yaml.j2
    │   ├── handlers/main.yml   restart k3s
    │   └── tasks/main.yml, kubeconfig.yml
    └── k3s_agent/         worker1·2: 토큰으로 합류
        ├── templates/config.yaml.j2
        ├── handlers/main.yml   restart k3s-agent
        └── tasks/main.yml
```

## 롤, 변수, 핸들러, 팩트가 각각 어디에 쓰였나

### 롤 (role)

- 관련된 작업·변수·템플릿·핸들러를 정해진 폴더 구조로 묶은 재사용 단위. 이름만 부르면 그 폴더 구조를 Ansible이 알아서 읽는다.
- `site.yml`은 "어느 그룹에 어떤 롤"만 적은 목차가 되고, 실제 내용은 롤 안에 있다.
  - `common` → `k3s_cluster` 그룹 전체 (3대)
  - `k3s_server` → `control_plane` 그룹 (cp1)
  - `k3s_agent` → `workers` 그룹 (worker1, worker2)
- 나중에 MySQL 롤, 모니터링 롤을 추가할 때도 같은 모양으로 늘린다.

### 변수 (variable)와 우선순위

- `roles/*/defaults/main.yml`: 롤의 기본값. 가장 우선순위가 낮아서 밖에서 쉽게 덮어쓸 수 있다.
  예: `common_timezone`, `common_sysctl`, `k3s_server_taints`, `k3s_disable`
- `group_vars/all.yml`: 인벤토리의 모든 서버에 적용되는 값. defaults보다 우선한다.
  예: `k3s_version: v1.36.5+k3s1` (버전 고정), `k3s_server_ip`, `kubeconfig_local_path`
- `-e`(extra vars): 명령줄에서 주는 값. 가장 우선한다. 예: `ansible-playbook k3s-uninstall.yml -e confirm=yes`
- `register`: 작업 결과를 변수로 저장. 예: `k3s_installed`(설치된 버전 출력), `k3s_install`(설치를 했는지)
- `set_fact`: 실행 중에 변수를 만든다. cp1에서 읽은 조인 토큰을 `k3s_token`으로 저장하고,
  에이전트 플레이에서 `hostvars['cp1']['k3s_token']`으로 다른 호스트의 변수를 꺼내 쓴다.

### 핸들러 (handler)

- 다른 작업이 `notify` 했을 때만 실행되는 작업. 여러 번 notify 돼도 한 번만 실행된다.
- `k3s 서버 설정 파일` 템플릿이 실제로 바뀌었을 때만 `restart k3s`가 돈다. 바뀐 게 없으면 서비스를 건드리지 않는다.
  → 플레이북을 아무리 자주 돌려도 멀쩡한 클러스터가 재시작되지 않는다.
- `meta: flush_handlers`: 원래 핸들러는 플레이 끝에 돈다. 재시작이 끝나야 "노드 Ready 대기"가 의미가 있으므로 그 전에 강제로 실행한다.
- `when: k3s_install is not changed`: 이번 실행에서 설치 스크립트가 돌았다면 스크립트가 이미 새 설정으로 서비스를 시작했으므로 재시작을 건너뛴다.
  (이 조건을 넣기 전에는 처음 설치할 때 쓸데없는 재시작이 한 번 더 있었고, 넣은 뒤 재설치 시간이 40초 → 31초로 줄었다)

### 팩트 (fact)

- 플레이 시작 때 `Gathering Facts` 단계에서 Ansible이 각 서버의 정보(IP, OS, 메모리, 스왑 등)를 모아 `ansible_facts`에 넣는다.
- 쓰인 곳:
  - `ansible_facts['distribution']`: Ubuntu인지 확인 (common)
  - `ansible_facts['swaptotal_mb']`: 스왑이 켜져 있을 때만 `swapoff` 실행 (common)
  - `ansible_facts['default_ipv4']['address']`: 각 노드의 `node-ip`, 서버 인증서의 `tls-san` (템플릿)
  - `hostvars['cp1']['ansible_facts']['default_ipv4']['address']`: 워커가 접속할 서버 주소, 맥 kubeconfig의 주소 (group_vars)
- 덕분에 IP를 어떤 파일에도 직접 적지 않았다. VM IP가 바뀌면 `site.yml`을 다시 돌리면 설정 파일이 새 IP로 바뀌고 핸들러가 재시작한다.
- 참고: 옛 문법 `ansible_swaptotal_mb`(팩트를 변수로 바로 쓰기)는 ansible-core 2.20부터 사용 중단 예정이라 `ansible_facts['...']` 형태로 썼다.

## 멱등성을 지키기 위해 한 것

- `command`는 Ansible이 결과를 알 수 없어 늘 "changed"로 보고한다. 그래서
  - 확인용 명령(`k3s --version`, `kubectl get node`)에는 `changed_when: false`
  - 설치 명령과 설치 스크립트 내려받기는 `when: k3s_version not in k3s_installed.stdout`으로 버전이 다를 때만 실행
  - 읽기만 하는 명령(버전 확인, Ready 대기)에는 `check_mode: false` → `--check` 미리 보기 때도 실제로 실행해야 판단이 맞다
  - 제거 스크립트는 `removes: /usr/local/bin/k3s-uninstall.sh`로 파일이 있을 때만 실행
- apt는 `cache_valid_time: 3600`으로 1시간 안에 갱신했으면 다시 갱신하지 않는다.
- kubeconfig는 `fetch` 대신 `slurp` + `copy`로 저장한다. fetch는 원본을 그대로 받아와서 주소를 고치면 매번 "다르다"고 다시 받는다.
- 결과 기록: [k3s-verification.md](k3s-verification.md)

## 설계 결정

### k3s 기본 구성요소: 전부 켜둔다

**Traefik (Ingress 컨트롤러): 켠다**
- 브라우저 → 클러스터 안의 서비스로 HTTP 요청을 넘겨주는 문지기. 플랫폼에서 Gateway 서비스 앞단이 된다.
- 끄고 ingress-nginx를 따로 설치하는 방법도 있지만, 메모리를 더 쓰고 설치 단계가 늘어난다.
  게다가 Kubernetes 프로젝트의 ingress-nginx는 2026년 3월로 유지보수가 끝났다. Traefik은 계속 개발되고 있고, 다음 표준인 Gateway API도 지원한다.
- 사용량: 파드 1개, 약 50~80MB.

**ServiceLB (klipper-lb): 켠다**
- `type: LoadBalancer` 서비스(Traefik)를 모든 노드 IP의 80/443 포트로 열어준다. 그래서 `http://192.168.252.2`처럼 아무 노드로 접속해도 된다.
- 클라우드라면 AWS ELB 같은 로드밸런서가 이 역할을 한다. 맥 안의 VM에는 그런 게 없으므로 ServiceLB가 대신한다.
- 대안인 MetalLB는 노드 IP와 다른 가상 IP를 줄 수 있지만 설정이 더 많다. 지금은 필요 없다.
- `svclb-traefik` 파드가 노드마다 하나씩(cp1 포함) 뜨는 것이 정상이다. 아주 가볍다(수 MB).

**local-path 스토리지: 켠다**
- 파드가 저장 공간(PVC)을 요청하면 그 노드의 디스크에 폴더(`/var/lib/rancher/k3s/storage/...`)를 만들어 연결해준다.
- 대안인 Longhorn(노드 간 복제)은 메모리를 노드마다 수백 MB 써서 우리 예산에 맞지 않는다. NFS는 서버가 하나 더 필요하다.

**metrics-server: 켠다**
- `kubectl top nodes/pods`와 나중의 자동 확장(HPA)에 필요하다. 약 30~50MB.

### cp1에 앱 파드 막기: taint를 건다

- `node-role.kubernetes.io/control-plane:NoSchedule` taint를 cp1에 붙였다.
- taint는 노드에 붙이는 "출입 금지" 표시, toleration은 파드가 가진 "출입증"이다. 출입증이 없는 일반 앱 파드는 cp1에 배치되지 않는다.
- 이유: cp1은 메모리가 2GB뿐이고 k3s 서버(API 서버, 스케줄러, 내장 DB)가 이미 900MB 넘게 쓴다.
  앱이 여기서 메모리를 다 쓰면 API 서버가 죽고, 그러면 클러스터 전체를 조작할 수 없다.
- 쿠버네티스 표준 이름의 taint라서 CoreDNS, metrics-server, local-path-provisioner 같은 k3s 기본 구성요소는 출입증이 있어 cp1에 뜬다. 메모리 계획과 일치한다.
- 확인: nginx 3개를 띄우면 worker1에 2개, worker2에 1개가 뜨고 cp1에는 0개다.
- 주의: k3s는 노드가 처음 등록될 때만 taint를 붙인다. 이미 있는 클러스터에서 바꾸려면 `kubectl taint nodes cp1 ...`로 직접 바꾼다.

### MySQL 데이터를 VM 재시작 후에도 남기기

어디까지 남는지부터 정리하면:
- 파드 재시작, 파드 삭제 후 재생성: local-path PV는 노드 디스크에 있으므로 남는다
- VM stop/start, 맥 재부팅: VM 디스크에 있으므로 남는다
- `k3s-uninstall.yml` 실행: `/var/lib/rancher/k3s` 아래가 통째로 지워지므로 **사라진다**
- VM 삭제(`delete-vms.sh`): **사라진다**
- PVC 삭제: local-path의 기본 reclaimPolicy가 `Delete`라서 **사라진다**

3단계(MySQL 배포)에서 이렇게 한다:
1. MySQL은 worker1에 고정한다 (`nodeSelector`). local-path 볼륨은 만들어진 노드에서만 쓸 수 있으므로, 어차피 다른 노드로 옮길 수 없다.
2. 데이터 폴더를 k3s 폴더 밖의 고정 경로(예: worker1의 `/srv/data/mysql`)로 두고, 그 경로를 가리키는 PV를 직접 만든다 (`persistentVolumeReclaimPolicy: Retain`).
   → k3s를 지우고 다시 설치해도, PVC를 실수로 지워도 데이터 폴더는 남고 다시 연결할 수 있다.
3. 정기 백업: `mysqldump` 결과를 맥으로 가져오는 Ansible 플레이북이나 CronJob을 만든다. 디스크 하나에만 있는 데이터는 언젠가 잃는다고 가정한다.
