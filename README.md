# Secure Dockerfile, Run Docker Container Securely & Push Image to ECR

A step-by-step walkthrough for securely containerizing and deploying a Django Notes/Poll
app on AWS EC2 using a multi-stage Dockerfile, hardened runtime flags, and AWS ECR.

## 🎯 Objective

Securely clone, containerize, and deploy a Django app on an Amazon EC2 instance using a
secure Dockerfile and a hardened `docker run` command, following real-world DevOps
security practices.

---

## 1. Clone the Repository

```bash
p
```

---

## 2. Launch an EC2 Instance

**Requirements:**
- AWS account with an IAM user that has EC2 permissions
- Security group with inbound rules for ports `22` (SSH), `80` (HTTP), `8000` (app)
- A key pair for SSH access

**Steps:**
1. AWS EC2 Console → Launch Instance
2. AMI: Ubuntu Server 22.04 LTS
3. Instance type: `t2.micro` (Free Tier) or higher
4. Configure security group with the ports above
5. Launch and download the key pair

**Connect via SSH:**
```bash
ssh -i "your-key.pem" ubuntu@your-ec2-public-ip
```

---

## 3. Run the App Locally (Without Docker) — For Testing

### 3.1 Set up a virtual environment

Modern Ubuntu blocks system-wide `pip install` ("externally managed environment" error),
so use a virtual environment instead:

```bash
sudo apt update
sudo apt install python3-venv python3-full -y

python3 -m venv venv
source venv/bin/activate
```

### 3.2 Fix and install requirements

> ⚠️ **Common issue:** if `requirements.txt` was copied from a PDF/Word doc, it often
> contains smart/curly quotes (`"..."`) instead of plain quotes, which breaks `pip
> install` with an `Invalid requirement` error. Open the file and make sure it looks
> exactly like this (no quotes around any line):

```
asgiref
Django>=4.2,<4.3
pytz==2020.5
sqlparse==0.4.4
gunicorn
```

> Note: `asgiref` is left unpinned so pip can resolve a version compatible with
> Django 4.2 automatically (a pinned old version caused a `ResolutionImpossible` error).
> `gunicorn` must be included — it's required later for the Docker container's start
> command.

```bash
pip install -r requirements.txt
```

### 3.3 Migrate and run

```bash
python manage.py migrate
python manage.py runserver 0.0.0.0:8000
```

### 3.4 Common runtime errors & fixes

**"You're accessing the development server over HTTPS, but it only supports HTTP"**
→ Use `http://` in the browser, not `https://`.

**`DisallowedHost` / `Invalid HTTP_HOST header`**
→ Add your EC2 public IP to `ALLOWED_HOSTS` in `settings.py`:
```python
ALLOWED_HOSTS = ['<your-ec2-public-ip>', 'localhost', '127.0.0.1']
```
(For local testing only, `ALLOWED_HOSTS = ['*']` also works — never use this in production.)

---

## 4. Why Security Matters

Running containers without hardening can expose a server to:
- Remote Code Execution
- Privilege Escalation
- Sensitive Data Leaks
- Unauthorized Access

"Hardening" a Dockerfile means the resulting image is **secure, minimal, predictable,
and resistant to attacks** — think of it as adding multiple layers of defense.

---

## 5. Secure, Multi-Stage Dockerfile

```dockerfile
# ============================================================
# Stage 1: Builder — only used to install dependencies.
# This stage is THROWN AWAY after build, so build tools
# (gcc, headers, etc.) never end up in the final image.
# ============================================================
FROM python:3.10-slim AS builder

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc \
    libpq-dev \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .

RUN pip install --no-cache-dir --target=/install -r requirements.txt


# ============================================================
# Stage 2: Final image — small, clean, no compilers, no root.
# ============================================================
FROM python:3.10-slim

RUN adduser --disabled-password --gecos '' appuser

WORKDIR /app

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONPATH="/install" \
    PATH="/install/bin:$PATH"

COPY --from=builder /install /install

COPY --chown=appuser:appuser . .

USER appuser

EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8000/')" || exit 1

CMD ["gunicorn", "pollme.wsgi:application", "--bind", "0.0.0.0:8000", "--workers", "3"]
```

> Replace `pollme.wsgi:application` with your actual project's WSGI path. Find it with:
> ```bash
> find . -name "wsgi.py"
> ```

### Why each choice matters

| Choice | Reason |
|---|---|
| Multi-stage build | Build tools (gcc, headers) are discarded after compiling — final image stays small |
| `python:3.10-slim` | ~150MB vs ~900MB for the full image |
| `--no-cache-dir` | Skips pip's download cache, saving space |
| `PYTHONDONTWRITEBYTECODE=1` | Avoids writing unnecessary `.pyc` files |
| Non-root `appuser` | The single most important container security practice |
| `COPY --chown=` | Sets ownership during copy instead of a separate `chown` layer |
| `HEALTHCHECK` in Dockerfile | Works even if `docker run` is called without explicit health flags |

### .dockerignore

```
.git
.gitignore
.env
__pycache__
*.pyc
*.pyo
*.sqlite3
venv/
env/
*.log
.vscode
.idea
README.md
```

---

## 6. Install Docker & Build the Image

```bash
sudo apt update
sudo apt install -y docker.io
sudo usermod -aG docker $USER
newgrp docker
```

```bash
docker build -t poll:latest .
```

---

## 7. Run the Container Securely

```bash
mkdir -p logs

docker run -d \
  --name poll-app \
  --restart unless-stopped \
  --user 1000:1000 \
  --read-only \
  --tmpfs /tmp \
  --cap-drop=ALL \
  --security-opt no-new-privileges \
  --memory=512m \
  --cpus=1.0 \
  -p 8000:8000 \
  -v "$(pwd)/logs:/app/logs:rw" \
  --health-cmd="curl -f http://localhost:8000/health || exit 1" \
  --health-interval=30s \
  --health-retries=3 \
  --health-start-period=10s \
  poll:latest
```

> ⚠️ **Quote warning:** if this command was copy-pasted from a document/PDF, the
> quotes around `$(pwd)/logs:/app/logs:rw` may turn into curly quotes (`"..."`),
> which Docker rejects with `invalid mode: rw"`. Always re-type the quotes as plain
> `"` characters, or strip and retype them manually.

### What each flag does

| Category | Flag | Why |
|---|---|---|
| Security | `--user 1000:1000` | Avoids root; reduces attack surface |
| Security | `--read-only` | Prevents writes to the filesystem |
| Security | `--tmpfs /tmp` | In-memory `/tmp` for apps needing temp files |
| Security | `--cap-drop=ALL` | Removes all Linux capabilities |
| Security | `--security-opt no-new-privileges` | Prevents privilege escalation |
| Stability | `--restart unless-stopped` | Auto-restarts on crash/reboot |
| Performance | `--memory`, `--cpus` | Prevents resource abuse |
| Health | `--health-*` | Ensures the container is healthy before routing traffic |
| Volume | `-v .../logs:/app/logs:rw` | Needed since the container itself is read-only |
| Port | `-p 8000:8000` | Maps host port to container port |

### Common errors & fixes

**`exec: "gunicorn": executable file not found in $PATH`**
→ `gunicorn` was missing from `requirements.txt`. Add it, then rebuild the image
(`docker build -t poll:latest .`) before running again.

**`Conflict. The container name "/poll-app" is already in use`**
→ Remove the old container first:
```bash
docker rm poll-app
# or, if it won't remove cleanly:
docker rm -f poll-app
```

Check it's running:
```bash
docker ps
```

Open in browser:
```
http://<your-ec2-public-ip>:8000
```

---

## 8. Push the Image to AWS ECR

### 8.1 Install AWS CLI

```bash
sudo apt update
sudo apt install unzip curl -y
curl https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip -o awscliv2.zip
unzip awscliv2.zip
sudo ./aws/install
aws --version
```

> ⚠️ Run the `curl` command on a single line — breaking it across lines (or smart
> quotes around the filename) causes `curl: option -o: requires parameter`.

### 8.2 Get AWS Credentials

1. AWS Console → IAM → Users → your username
2. Security credentials → Create access key
3. Copy the **Access Key ID** and **Secret Access Key**

### 8.3 Configure AWS CLI

```bash
aws configure
```

Enter your Access Key ID, Secret Access Key, default region (e.g. `us-east-1`), and
output format (`json`).

### 8.4 Create ECR Repository

```bash
aws ecr create-repository --repository-name poll-app
```

### 8.5 Authenticate, Tag & Push

```bash
aws ecr get-login-password --region <your-region> | docker login \
  --username AWS --password-stdin <aws_account_id>.dkr.ecr.<your-region>.amazonaws.com

docker tag poll:latest \
  <aws_account_id>.dkr.ecr.<your-region>.amazonaws.com/poll-app:latest

docker push \
  <aws_account_id>.dkr.ecr.<your-region>.amazonaws.com/poll-app:latest
```

### 8.6 Pull From ECR

```bash
docker pull <aws_account_id>.dkr.ecr.<your-region>.amazonaws.com/poll-app:latest
```

---

## 📦 Additional Recommendations

| Area | Recommendation |
|---|---|
| `.dockerignore` | Exclude `.env`, `__pycache__`, `.git`, etc. |
| `.env` usage | Load secrets via environment variables, never hardcode |
| HTTPS | Use Nginx + Certbot in production |
| CI/CD | Scan images with Trivy or Dockle |
| Database | Use PostgreSQL remotely or in a separate container |

---

## ✅ Conclusion

This walkthrough covered securely deploying a Django app from GitHub on AWS EC2 using
Docker with a multi-stage Dockerfile, a hardened container runtime, minimal privileges,
resource limits, and filesystem protection — then pushing the resulting image to AWS ECR.
