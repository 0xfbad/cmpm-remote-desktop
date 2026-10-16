# remote-desktop

Kali XFCE image for the CTFd remote desktop plugin.

```sh
docker build --platform linux/amd64 -t ctfd-remote-desktop .
nix flake check
```

For a course CA, add `--secret id=ucsc_ca,src=ca.pem --build-arg UCSC_CA_CERT_SHA256=<der-sha256>` to the build.
