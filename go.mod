module app

go 1.25

require (
	github.com/coreos/go-systemd v0.0.0-20191104093116-d3cd4ed1dbcf
	github.com/go-chi/chi v1.5.5
	maragu.dev/gomponents v1.0.0
)

replace github.com/coreos/bbolt => go.etcd.io/bbolt v1.4.0
