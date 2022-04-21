go install golang.org/dl/go1.16.4@v0.0.0-20210506185525-b8dea299038d
go1.16.4 download
export GOROOT=$HOME/sdk/go1.16.4
export PATH=$GOROOT/bin:$PATH
# Disable external tool invocations (e.g. gcc and ld).
export CGO_ENABLED=0 GO_EXTLINK_ENABLED=0
# Trim absolute paths.
export GOFLAGS=-trimpath
# Target the same OS and arch.
export GOOS=linux GOARCH=amd64
mkdir nixpkgs-reproduce && cd nixpkgs-reproduce
go mod init example.com/main
cat >main.go <<EOF
package main

func main() {
	println("hello world")
}
EOF
go build -o main
shasum main