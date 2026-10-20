# VM 멈추기·켜기, IP가 바뀌었을 때

## 상태 보기

```bash
multipass list            # 이름, 상태(Running/Stopped), IP
multipass info cp1        # CPU·메모리·디스크 사용량까지
```

## 멈추기와 켜기

```bash
multipass stop --all      # 전부 끄기 (디스크는 그대로 남는다)
multipass start --all     # 전부 켜기
multipass stop worker2    # 하나만 끄기
multipass restart cp1     # 재부팅
```

- 끄면 VM이 쓰던 메모리가 맥으로 돌아온다. 클러스터를 안 쓸 때는 꺼두면 맥이 가벼워진다.
- 켤 때 순서: k3s를 설치한 뒤에는 cp1을 먼저 켜고, 워커를 켠다 (워커가 cp1에 접속하기 때문). 끌 때는 반대로 워커 → cp1.
  ```bash
  multipass start cp1 && multipass start worker1 worker2
  multipass stop worker1 worker2 && multipass stop cp1
  ```
- `suspend`(일시정지)도 있지만 시계가 어긋나거나 네트워크가 꼬일 수 있어 쿠버네티스에는 `stop`을 권한다.
- 맥을 재부팅하면 VM은 꺼진 상태로 남는다. 다시 `multipass start --all`.

## 켠 뒤 확인 순서

```bash
multipass list                     # 1) IP가 예전과 같은지 본다
multipass/check-network.sh         # 2) 통신 확인
cd ansible && ansible all -m ping  # 3) Ansible 연결 확인
```

## IP가 바뀌었을 때

증상:
- `ssh cp1`이 멈춰 있다가 `Connection timed out` (예전 IP로 접속하려 해서)
- `ansible all -m ping`이 `UNREACHABLE`

해결:

```bash
multipass/update-hosts.sh
```

이 스크립트가 고치는 곳은 두 군데뿐이다.
1. 맥의 `~/.ssh/config.d/platform-infra` (ssh 별칭 → 새 IP). Ansible 인벤토리는 별칭을 쓰므로 함께 해결된다.
2. 각 VM의 `/etc/hosts` (VM끼리 이름으로 찾는 주소)

호스트 키를 이름(`HostKeyAlias`)으로 기억하므로 IP가 바뀌어도 "호스트 키가 바뀌었다"는 경고는 나지 않는다.

주의: k3s를 설치한 뒤(2단계 이후)에는 노드 IP가 k3s 설정과 인증서에도 들어간다. 그때 IP가 바뀌면 추가 조치가 필요하며 2단계 문서에서 다룬다.
그래서 IP가 자주 바뀌지 않게 VM은 지우지 말고 stop/start로만 쓰는 것이 좋다.

## IP가 왜 바뀌나

- VM은 맥의 DHCP 서버(bootpd)에게 IP를 빌린다. 맥은 VM의 MAC 주소별로 기억해서 보통 같은 IP를 다시 준다.
- 바뀌는 경우: VM을 지우고 다시 만들 때 (MAC 주소가 새로 생김), 임대 기록이 정리됐을 때, macOS 업데이트 후 등.
- 임대 기록 보기: `cat /var/db/dhcpd_leases`

## 문제 해결

- `multipass list`에서 IP가 `--`로 나온다 → VM이 아직 부팅 중이다. 30초쯤 기다린다. 계속 그러면 `multipass restart <이름>`.
- `multipass` 명령이 멈춘다 → 맥의 시스템 설정 > 개인정보 보호 및 보안 > 로컬 네트워크에서 Multipass 허용 여부를 확인하거나, 데몬 재시작:
  `sudo launchctl kickstart -k system/com.canonical.multipassd`
- 처음부터 다시 하고 싶다 → `multipass/delete-vms.sh` 후 `multipass/create-vms.sh`
