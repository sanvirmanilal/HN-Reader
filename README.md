# HN Reader with Podman

This app uses Node.js built-in modules only; no `npm install` is needed. From a
shell in your WSL distribution with Podman installed, change to this directory
(for example, `cd '/mnt/c/path/to/HN Reader'`) and run:

```sh
podman build -t localhost/hn-reader:latest -f Containerfile .
podman kube play --publish 127.0.0.1:4173:4173 pod.yaml
```

The Node base image comes from the public ECR mirror of the official Node
image, so building does not require Docker Hub access.

Open <http://localhost:4173> in your browser. The pod publishes the app only
on the WSL host's loopback interface; WSL localhost forwarding normally makes
it available from Windows as well. The server needs outbound HTTPS access for
the Hacker News feed and articles. The pod mounts a read-only CA bundle from
the WSL/Podman host at `/home/user/.config/hn-reader/ca-bundle.pem` for Node
TLS verification. This bundle should include the distribution's normal CA
certificates and, on a TLS-inspecting network, the trusted corporate root CA.
Obtain corporate certificates from your IT team; do not commit them to this
repository. Create or update the bundle when certificates change, and adjust
`hostPath.path` in `pod.yaml` if your WSL username or bundle location differs.

To see the pod or its logs:

```sh
podman pod ps
podman logs hn-reader-hn-reader
```

After editing the app, rebuild the image and recreate the pod:

```sh
podman build -t localhost/hn-reader:latest -f Containerfile .
podman kube play --replace --publish 127.0.0.1:4173:4173 pod.yaml
```

To remove the pod:

```sh
podman kube down pod.yaml
```

Direct execution with `node server.js` still listens only on `127.0.0.1:4173`.
The container image sets `HOST=0.0.0.0` so the pod can reach the app through
its published port.
