// Package requestid는 Traefik 로컬 플러그인이다 (Yaegi가 Go 소스를 그대로 해석해서 실행한다. 컴파일 없음).
// 요청마다 요청 ID 헤더를 정한다:
//   - 클라이언트가 보낸 값이 형식에 맞으면 그대로 쓴다 (앞단 시스템과 추적을 이어 붙일 수 있게)
//   - 없거나 형식이 틀리면 새 UUID(v4)를 만든다 (로그에 이상한 글자가 들어가는 것을 막는다)
// 같은 값을 백엔드로 가는 요청 헤더와 클라이언트로 가는 응답 헤더에 모두 넣는다.
// → Traefik 접근 로그, 앱 로그, 클라이언트가 받은 응답을 같은 ID로 이어 볼 수 있다.
package requestid

import (
	"context"
	"crypto/rand"
	"fmt"
	"net/http"
)

// Config는 미들웨어 설정 (Middleware 객체의 spec.plugin.requestid 아래 값)
type Config struct {
	HeaderName string `json:"headerName,omitempty"`
}

// CreateConfig는 기본 설정을 만든다 (Traefik이 부른다)
func CreateConfig() *Config {
	return &Config{HeaderName: "X-Request-Id"}
}

// RequestID 미들웨어
type RequestID struct {
	next   http.Handler
	header string
}

// New는 미들웨어를 만든다 (Traefik이 부른다)
func New(_ context.Context, next http.Handler, config *Config, _ string) (http.Handler, error) {
	if config.HeaderName == "" {
		return nil, fmt.Errorf("headerName이 비어 있습니다")
	}
	return &RequestID{next: next, header: config.HeaderName}, nil
}

func (m *RequestID) ServeHTTP(rw http.ResponseWriter, req *http.Request) {
	id := req.Header.Get(m.header)
	if !valid(id) {
		id = newID()
	}
	req.Header.Set(m.header, id)
	rw.Header().Set(m.header, id)
	m.next.ServeHTTP(rw, req)
}

// 8~64자, 영문·숫자·-·_·. 만 허용
func valid(id string) bool {
	if len(id) < 8 || len(id) > 64 {
		return false
	}
	for _, c := range id {
		ok := (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' || c == '_' || c == '.'
		if !ok {
			return false
		}
	}
	return true
}

// UUID v4 (무작위 122비트)
func newID() string {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		return "unknown-request-id"
	}
	b[6] = (b[6] & 0x0f) | 0x40
	b[8] = (b[8] & 0x3f) | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16])
}
