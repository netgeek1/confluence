#!/usr/bin/env bash
set -euo pipefail

# confluence-exporter-installer.sh
# All-in-one installer and scaffolder for Confluence Cloud ZIP -> Combined export pipeline
# - Scaffolds project under /opt/confluence-exporter
# - Builds Docker image
# - Runs a local web UI to upload Confluence Cloud export ZIP, process, and download final ZIP
# - Output structure: both top-level and per-page (Option C)
#
# Usage: bash confluence-exporter-installer.sh
#
# NOTE: This script uses sudo for privileged operations. It does NOT re-exec itself with sudo.

APP_NAME="confluence-exporter"
IMAGE_NAME="confluence-exporter:latest"
PROJECT_ROOT="/opt/${APP_NAME}"
INPUT_DIR="${PROJECT_ROOT}/input"
OUTPUT_DIR="${PROJECT_ROOT}/app/output"
LOG_DIR="${PROJECT_ROOT}/app/logs"
TMP_DIR="${PROJECT_ROOT}/tmp"

RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[1;33m"
NC="\033[0m"

pause() { read -rp "Press Enter to continue..."; }

detect_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        echo "${ID:-unknown}"
    else
        echo "unknown"
    fi
}

check_docker_installed() {
    if command -v docker >/dev/null 2>&1; then
        echo -e "${GREEN}[OK]${NC} Docker is installed."
        return 0
    else
        echo -e "${RED}[WARN]${NC} Docker is not installed."
        return 1
    fi
}

install_docker() {
    if check_docker_installed; then
        echo -e "${GREEN}[OK]${NC} Docker already installed, skipping."
        return 0
    fi

    local os_id
    os_id=$(detect_os)
    echo -e "${YELLOW}[INFO]${NC} Detected OS: ${os_id}"

    case "$os_id" in
        ubuntu|debian)
            echo -e "${YELLOW}[INFO]${NC} Installing Docker for Debian/Ubuntu..."
            sudo apt-get update
            sudo apt-get install -y ca-certificates curl gnupg lsb-release

            sudo install -m 0755 -d /etc/apt/keyrings
            curl -fsSL "https://download.docker.com/linux/${os_id}/gpg" \
                | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
            sudo chmod a+r /etc/apt/keyrings/docker.gpg

            echo \
              "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${os_id} \
              $(lsb_release -cs) stable" \
              | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null

            sudo apt-get update
            sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

            sudo systemctl enable docker
            sudo systemctl start docker
            ;;
        rhel|centos|rocky|almalinux)
            echo -e "${YELLOW}[INFO]${NC} Installing Docker for RHEL/CentOS-like..."
            sudo yum install -y yum-utils
            sudo yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
            sudo yum install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
            sudo systemctl enable docker
            sudo systemctl start docker
            ;;
        *)
            echo -e "${RED}[ERROR]${NC} Unsupported OS for automatic Docker install. Install Docker manually."
            return 1
            ;;
    esac

    echo -e "${GREEN}[OK]${NC} Docker installed and service started."
}

ensure_docker_group() {
    if ! getent group docker >/dev/null 2>&1; then
        echo -e "${YELLOW}[INFO]${NC} Creating docker group..."
        sudo groupadd docker || true
    fi

    local user="${USER}"
    if id -nG "$user" | grep -qw docker; then
        echo -e "${GREEN}[OK]${NC} User '$user' is already in docker group."
    else
        echo -e "${YELLOW}[INFO]${NC} Adding user '$user' to docker group..."
        sudo usermod -aG docker "$user"
        echo -e "${YELLOW}[INFO]${NC} You may need to log out and back in, or run: newgrp docker"
    fi
}

fix_docker_permissions() {
    local user="${USER}"
    local home_dir
    home_dir=$(getent passwd "$user" | cut -d: -f6)

    if [[ -d "$home_dir/.docker" ]]; then
        echo -e "${YELLOW}[INFO]${NC} Fixing permissions on $home_dir/.docker..."
        sudo chown "$user":"$user" "$home_dir/.docker" -R
        sudo chmod g+rwx "$home_dir/.docker" -R
    else
        echo -e "${YELLOW}[INFO]${NC} No ~/.docker directory to fix."
    fi
}

verify_docker() {
    echo -e "${YELLOW}[INFO]${NC} Running 'docker run --rm hello-world'..."
    if docker run --rm hello-world >/dev/null 2>&1; then
        echo -e "${GREEN}[OK]${NC} Docker is working."
    else
        echo -e "${RED}[ERROR]${NC} Docker test failed."
    fi
}

prepare_project_root() {
    if [[ ! -d "${PROJECT_ROOT}" ]]; then
        echo -e "${YELLOW}[INFO]${NC} Creating ${PROJECT_ROOT}..."
        sudo mkdir -p "${PROJECT_ROOT}"
        sudo chown -R "$USER":"$USER" "${PROJECT_ROOT}"
    fi
    mkdir -p "${INPUT_DIR}"
    mkdir -p "${OUTPUT_DIR}"
    mkdir -p "${LOG_DIR}"
    mkdir -p "${TMP_DIR}"
}

create_project_structure() {
    echo -e "${YELLOW}[INFO]${NC} Creating project structure at ${PROJECT_ROOT}..."
    mkdir -p "${PROJECT_ROOT}"/{docker,app,bootstrap}
    mkdir -p "${PROJECT_ROOT}/app"/{core,parser,transformers,uploader,cli,api,ui,output,logs}
    mkdir -p "${PROJECT_ROOT}/app/transformers"/{markdown,docx,html,attachments}
    mkdir -p "${PROJECT_ROOT}/app/api"/{routes,websocket}
    mkdir -p "${PROJECT_ROOT}/app/ui"/{static,templates}
    mkdir -p "${PROJECT_ROOT}/app/output"
    mkdir -p "${PROJECT_ROOT}/app/logs"
    mkdir -p "${PROJECT_ROOT}/app/tmp"
    touch "${PROJECT_ROOT}/app/__init__.py"
    touch "${PROJECT_ROOT}/app/core/__init__.py"
    touch "${PROJECT_ROOT}/app/parser/__init__.py"
    touch "${PROJECT_ROOT}/app/transformers/__init__.py"
    touch "${PROJECT_ROOT}/app/uploader/__init__.py"
    touch "${PROJECT_ROOT}/app/cli/__init__.py"
    touch "${PROJECT_ROOT}/app/api/__init__.py"
    touch "${PROJECT_ROOT}/app/ui/__init__.py"
}

write_dockerfile() {
    cat > "${PROJECT_ROOT}/docker/Dockerfile" <<'EOF'
FROM python:3.12-slim

WORKDIR /app

RUN apt-get update && apt-get install -y \
    build-essential \
    libxml2-dev \
    libxslt1-dev \
    libmagic1 \
    curl \
    unzip \
    && rm -rf /var/lib/apt/lists/*

COPY docker/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app/ /app/

COPY docker/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

RUN useradd -m exporter || true
USER exporter

EXPOSE 8080

ENTRYPOINT ["/entrypoint.sh"]
EOF
}

write_requirements() {
    cat > "${PROJECT_ROOT}/docker/requirements.txt" <<'EOF'
fastapi
uvicorn[standard]
python-multipart
jinja2
boxsdk
lxml
beautifulsoup4
markdown
python-docx
pyyaml
aiofiles
websockets
requests
python-dateutil
EOF
}

write_entrypoint() {
    cat > "${PROJECT_ROOT}/docker/entrypoint.sh" <<'EOF'
#!/usr/bin/env bash
set -e

# Ensure Python can import from /app
export PYTHONPATH=/app

MODE="ui"
EXTRA_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --api)
            MODE="api"
            shift
            ;;
        --ui)
            MODE="ui"
            shift
            ;;
        cli)
            MODE="cli"
            shift
            ;;
        *)
            EXTRA_ARGS+=("$1")
            shift
            ;;
    esac
done

echo "[entrypoint] Mode: $MODE"

if [[ "$MODE" == "cli" ]]; then
    python3 /app/main.py cli "${EXTRA_ARGS[@]}"
    exit $?
fi

if [[ "$MODE" == "api" || "$MODE" == "ui" ]]; then
    exec uvicorn api.api:app --host 0.0.0.0 --port 8080
fi

echo "[entrypoint] Unknown mode: $MODE"
exit 1
EOF
    chmod +x "${PROJECT_ROOT}/docker/entrypoint.sh"
}

write_config_yaml() {
    cat > "${PROJECT_ROOT}/app/config.yaml" <<'EOF'
input:
  zip_path: "/input/export.zip"

output:
  base_dir: "/app/output"
  zip_output_dir: "/app/output"
  keep_temp: false

processing:
  max_workers: 2

logging:
  level: "INFO"
EOF
}

write_core_files() {
    cat > "${PROJECT_ROOT}/app/core/config_loader.py" <<'EOF'
from pathlib import Path
import yaml

DEFAULT_CONFIG_PATH = Path("/app/config.yaml")

def load_config(path: str | None = None) -> dict:
    cfg_path = Path(path) if path else DEFAULT_CONFIG_PATH
    if not cfg_path.exists():
        return {}
    with cfg_path.open("r", encoding="utf-8") as f:
        return yaml.safe_load(f) or {}
EOF

    cat > "${PROJECT_ROOT}/app/core/logger.py" <<'EOF'
import logging
from pathlib import Path

LOG_DIR = Path("/app/logs")
LOG_DIR.mkdir(parents=True, exist_ok=True)

def get_logger(name: str = "confluence-exporter") -> logging.Logger:
    logger = logging.getLogger(name)
    if logger.handlers:
        return logger
    logger.setLevel(logging.INFO)
    fmt = logging.Formatter("[%(asctime)s] [%(levelname)s] %(message)s")
    fh = logging.FileHandler(LOG_DIR / "run.log")
    fh.setFormatter(fmt)
    ch = logging.StreamHandler()
    ch.setFormatter(fmt)
    logger.addHandler(fh)
    logger.addHandler(ch)
    return logger
EOF

    cat > "${PROJECT_ROOT}/app/core/zip_utils.py" <<'EOF'
import zipfile
from pathlib import Path
import shutil

def extract_zip(zip_path: str, extract_to: str) -> None:
    z = Path(zip_path)
    dest = Path(extract_to)
    if dest.exists():
        shutil.rmtree(dest)
    dest.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(str(z), 'r') as zf:
        zf.extractall(str(dest))

def create_zip(source_dir: str, output_zip_path: str) -> None:
    src = Path(source_dir)
    out = Path(output_zip_path)
    if out.exists():
        out.unlink()
    with zipfile.ZipFile(str(out), 'w', zipfile.ZIP_DEFLATED) as zf:
        for root, dirs, files in __import__('os').walk(str(src)):
            for f in files:
                full = Path(root) / f
                rel = full.relative_to(src)
                zf.write(str(full), str(rel))
EOF
}

write_parser_files() {
    cat > "${PROJECT_ROOT}/app/parser/ir_model.py" <<'EOF'
from dataclasses import dataclass, field
from typing import List, Optional, Dict

@dataclass
class Page:
    id: str
    title: str
    parent_id: Optional[str]
    content: str
    attachments: List[Dict] = field(default_factory=list)
    metadata: Dict = field(default_factory=dict)

@dataclass
class SpaceIR:
    pages: List[Page]
    metadata: Dict = field(default_factory=dict)
EOF

    cat > "${PROJECT_ROOT}/app/parser/cloud_parser.py" <<'EOF'
from pathlib import Path
from lxml import etree
from .ir_model import Page, SpaceIR
import json

def parse_confluence_cloud_export(extract_dir: str) -> SpaceIR:
    """
    Parse a Confluence Cloud export extracted into extract_dir.
    Expects:
      - entities.xml at root
      - pages/ directory with page bodies (page-<id>.xml or similar)
      - attachments/ directory with attachments
    This is a best-effort parser: Cloud export formats vary; this handles common patterns.
    """
    root = Path(extract_dir)
    entities = root / "entities.xml"
    if not entities.exists():
        raise FileNotFoundError(f"entities.xml not found in {extract_dir}")

    tree = etree.parse(str(entities))
    doc = tree.getroot()

    # Attempt to extract space metadata
    metadata = {}
    space_el = doc.find(".//object[@class='Space']")
    if space_el is not None:
        try:
            space_key = space_el.findtext("key") or space_el.findtext("spaceKey") or ""
            space_name = space_el.findtext("name") or ""
            metadata["space_key"] = space_key
            metadata["space_name"] = space_name
        except Exception:
            pass

    pages = []
    # Cloud export often uses <object class="Page"> with nested properties
    for obj in doc.findall(".//object[@class='Page']"):
        pid = obj.findtext("id") or obj.findtext("pageId") or ""
        title = obj.findtext("title") or f"Page-{pid}"
        parent_id = obj.findtext("parentId") or None

        # Body may be stored in pages/<id>.xml or pages/<id>.html; try to locate
        content = ""
        page_file_candidates = [
            root / "pages" / f"{pid}.xml",
            root / "pages" / f"page-{pid}.xml",
            root / "pages" / f"{pid}.html",
            root / "pages" / f"{title}.xml"
        ]
        for cand in page_file_candidates:
            if cand.exists():
                try:
                    # If XML, try to extract body content
                    if cand.suffix == ".xml":
                        try:
                            p_tree = etree.parse(str(cand))
                            # Common path: /page/body/storage or similar
                            body = p_tree.findtext(".//body") or p_tree.findtext(".//storage") or ""
                            content = body or ""
                        except Exception:
                            content = cand.read_text(encoding="utf-8", errors="ignore")
                    else:
                        content = cand.read_text(encoding="utf-8", errors="ignore")
                except Exception:
                    content = ""
                break

        # Attachments: look under attachments/<pid> or attachments/<title>
        attachments = []
        att_dirs = [
            root / "attachments" / pid,
            root / "attachments" / title,
            root / "attachments"
        ]
        for ad in att_dirs:
            if ad.exists() and ad.is_dir():
                for f in ad.iterdir():
                    if f.is_file():
                        attachments.append({"name": f.name, "path": str(f.relative_to(root))})
                if attachments:
                    break

        pages.append(Page(id=str(pid), title=title, parent_id=parent_id, content=content, attachments=attachments))

    # Fallback: if no Page objects found, try to parse pages/ directory directly
    if not pages and (root / "pages").exists():
        for pfile in (root / "pages").iterdir():
            if pfile.is_file():
                pid = pfile.stem
                title = pfile.stem
                try:
                    content = pfile.read_text(encoding="utf-8", errors="ignore")
                except Exception:
                    content = ""
                attachments = []
                pages.append(Page(id=str(pid), title=title, parent_id=None, content=content, attachments=attachments))

    return SpaceIR(pages=pages, metadata=metadata)
EOF
}

write_transformers() {
    cat > "${PROJECT_ROOT}/app/transformers/markdown/markdown_generator.py" <<'EOF'
from pathlib import Path
from parser.ir_model import SpaceIR
import re

def sanitize_name(name: str) -> str:
    s = re.sub(r'[\\/:<>\"|?*]', '_', name)
    s = s.strip()
    return s or "untitled"

def generate_markdown(ir: SpaceIR, out_dir: str) -> None:
    base = Path(out_dir)
    base.mkdir(parents=True, exist_ok=True)
    for page in ir.pages:
        safe_title = sanitize_name(page.title)
        out_file = base / f"{safe_title}.md"
        with out_file.open("w", encoding="utf-8") as f:
            f.write(f"# {page.title}\n\n")
            f.write(page.content or "")
EOF

    cat > "${PROJECT_ROOT}/app/transformers/docx/docx_generator.py" <<'EOF'
from pathlib import Path
from docx import Document
from parser.ir_model import SpaceIR
import re

def sanitize_name(name: str) -> str:
    s = re.sub(r'[\\/:<>\"|?*]', '_', name)
    s = s.strip()
    return s or "untitled"

def generate_docx(ir: SpaceIR, out_dir: str) -> None:
    base = Path(out_dir)
    base.mkdir(parents=True, exist_ok=True)
    for page in ir.pages:
        safe_title = sanitize_name(page.title)
        doc = Document()
        doc.add_heading(page.title, level=1)
        doc.add_paragraph(page.content or "")
        out_file = base / f"{safe_title}.docx"
        doc.save(out_file)
EOF

    cat > "${PROJECT_ROOT}/app/transformers/html/html_generator.py" <<'EOF'
from pathlib import Path
from parser.ir_model import SpaceIR
import re
from html import escape

def sanitize_name(name: str) -> str:
    s = re.sub(r'[\\/:<>\"|?*]', '_', name)
    s = s.strip()
    return s or "untitled"

def generate_html(ir: SpaceIR, out_dir: str) -> None:
    base = Path(out_dir)
    base.mkdir(parents=True, exist_ok=True)
    for page in ir.pages:
        safe_title = sanitize_name(page.title)
        out_file = base / f"{safe_title}.html"
        with out_file.open("w", encoding="utf-8") as f:
            f.write("<!doctype html><html><head><meta charset='utf-8'>")
            f.write(f"<title>{escape(page.title)}</title></head><body>\n")
            f.write(f"<h1>{escape(page.title)}</h1>\n")
            f.write(page.content or "")
            f.write("\n</body></html>")
EOF

    cat > "${PROJECT_ROOT}/app/transformers/attachments/attachment_handler.py" <<'EOF'
from pathlib import Path
import shutil

def copy_attachments_flat(extract_root: str, dest_dir: str) -> None:
    src = Path(extract_root)
    dest = Path(dest_dir)
    dest.mkdir(parents=True, exist_ok=True)
    # Copy all files under attachments/ into dest (flat)
    att_root = src / "attachments"
    if not att_root.exists():
        return
    for root, dirs, files in __import__('os').walk(str(att_root)):
        for f in files:
            full = Path(root) / f
            try:
                shutil.copy2(full, dest / f)
            except Exception:
                # if name collision, prefix with parent dir
                parent = Path(root).name
                shutil.copy2(full, dest / f"{parent}_{f}")

def copy_attachments_by_page(extract_root: str, dest_dir: str) -> None:
    src = Path(extract_root)
    dest = Path(dest_dir)
    dest.mkdir(parents=True, exist_ok=True)
    att_root = src / "attachments"
    if not att_root.exists():
        return
    for child in att_root.iterdir():
        if child.is_dir():
            target = dest / child.name
            target.mkdir(parents=True, exist_ok=True)
            for f in child.iterdir():
                if f.is_file():
                    try:
                        shutil.copy2(f, target / f.name)
                    except Exception:
                        pass
        elif child.is_file():
            # some exports put attachments directly under attachments/
            try:
                shutil.copy2(child, dest / child.name)
            except Exception:
                pass
EOF
}

write_ui_files() {
    # Simple single-page UI using fetch
    cat > "${PROJECT_ROOT}/app/ui/templates/index.html" <<'EOF'
<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <title>Confluence Exporter</title>
  <style>
    body { font-family: Arial, sans-serif; margin: 2rem; }
    .box { border: 1px solid #ddd; padding: 1rem; border-radius: 6px; max-width: 800px; }
    .status { margin-top: 1rem; }
    .hidden { display: none; }
    .progress { margin-top: 1rem; }
    button { padding: 0.5rem 1rem; }
  </style>
</head>
<body>
  <div class="box">
    <h1>Confluence Cloud ZIP → Combined Export</h1>
    <p>Upload a Confluence Cloud export ZIP. The server will process it and produce a combined ZIP containing both top-level and per-page outputs.</p>

    <input id="fileInput" type="file" accept=".zip" />
    <button id="uploadBtn">Upload & Process</button>

    <div class="status" id="statusArea"></div>
    <div class="progress" id="progressArea"></div>
    <div id="downloadArea"></div>
  </div>

<script>
async function postFile(file) {
  const form = new FormData();
  form.append('file', file);
  const res = await fetch('/upload', { method: 'POST', body: form });
  return res.json();
}

async function getStatus(id) {
  const res = await fetch('/status/' + id);
  return res.json();
}

async function getDownloadLink(id) {
  return '/download/' + id;
}

document.getElementById('uploadBtn').addEventListener('click', async () => {
  const fi = document.getElementById('fileInput');
  if (!fi.files.length) {
    alert('Select a ZIP file first.');
    return;
  }
  const file = fi.files[0];
  document.getElementById('statusArea').innerText = 'Uploading...';
  const j = await postFile(file);
  if (j.job_id) {
    const jobId = j.job_id;
    document.getElementById('statusArea').innerText = 'Queued. Job ID: ' + jobId;
    document.getElementById('progressArea').innerText = '';
    const poll = setInterval(async () => {
      const s = await getStatus(jobId);
      document.getElementById('statusArea').innerText = 'Status: ' + s.status + (s.message ? ' - ' + s.message : '');
      if (s.status === 'done') {
        clearInterval(poll);
        const link = getDownloadLink(jobId);
        document.getElementById('downloadArea').innerHTML = '<p><a href="' + link + '">Download export ZIP</a></p>';
      } else if (s.status === 'error') {
        clearInterval(poll);
      }
    }, 1500);
  } else {
    document.getElementById('statusArea').innerText = 'Upload failed.';
  }
});
</script>
</body>
</html>
EOF
}

write_api() {
    cat > "${PROJECT_ROOT}/app/api/api.py" <<'EOF'
from fastapi import FastAPI, UploadFile, File, HTTPException
from fastapi.responses import FileResponse, JSONResponse
from core.logger import get_logger
from core.zip_utils import extract_zip, create_zip
from parser.cloud_parser import parse_confluence_cloud_export
from transformers.markdown.markdown_generator import generate_markdown
from transformers.docx.docx_generator import generate_docx
from transformers.html.html_generator import generate_html
from transformers.attachments.attachment_handler import copy_attachments_flat, copy_attachments_by_page
from pathlib import Path
import uuid
import shutil
import json
import datetime
import os

logger = get_logger()
app = FastAPI(title="Confluence Exporter API")

BASE_DIR = Path("/app")
WORK_DIR = BASE_DIR / "tmp"
OUTPUT_DIR = BASE_DIR / "output"

# Simple in-memory job store (pid -> status). For production, replace with persistent store.
JOBS = {}

def timestamp():
    return datetime.datetime.utcnow().strftime("%Y%m%d-%H%M%S")

@app.post("/upload")
async def upload(file: UploadFile = File(...)):
    if not file.filename.endswith(".zip"):
        raise HTTPException(status_code=400, detail="Only ZIP files are accepted")
    job_id = str(uuid.uuid4())
    job_dir = WORK_DIR / job_id
    extract_dir = job_dir / "extracted"
    out_dir = job_dir / "export"
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    try:
        job_dir.mkdir(parents=True, exist_ok=True)
        zip_path = job_dir / "input.zip"
        with zip_path.open("wb") as f:
            content = await file.read()
            f.write(content)
        JOBS[job_id] = {"status": "queued", "message": ""}
        # Process synchronously but update status
        JOBS[job_id]["status"] = "processing"
        try:
            extract_zip(str(zip_path), str(extract_dir))
            # Parse
            ir = parse_confluence_cloud_export(str(extract_dir))
            # Prepare export structure
            out_dir.mkdir(parents=True, exist_ok=True)
            meta = {
                "job_id": job_id,
                "generated_at": timestamp(),
                "space_key": ir.metadata.get("space_key", ""),
                "space_name": ir.metadata.get("space_name", ""),
                "page_count": len(ir.pages)
            }
            # Top-level dirs
            top_md = out_dir / "top-level" / "markdown"
            top_html = out_dir / "top-level" / "html"
            top_docx = out_dir / "top-level" / "docx"
            top_att_flat = out_dir / "top-level" / "attachments-flat"
            top_att_by_page = out_dir / "top-level" / "attachments-by-page"
            per_page_root = out_dir / "per-page"
            top_md.mkdir(parents=True, exist_ok=True)
            top_html.mkdir(parents=True, exist_ok=True)
            top_docx.mkdir(parents=True, exist_ok=True)
            top_att_flat.mkdir(parents=True, exist_ok=True)
            top_att_by_page.mkdir(parents=True, exist_ok=True)
            per_page_root.mkdir(parents=True, exist_ok=True)

            # Generate top-level outputs
            generate_markdown(ir, str(top_md))
            generate_docx(ir, str(top_docx))
            generate_html(ir, str(top_html))

            # Copy attachments
            copy_attachments_flat(str(extract_dir), str(top_att_flat))
            copy_attachments_by_page(str(extract_dir), str(top_att_by_page))

            # Per-page outputs
            for page in ir.pages:
                safe = page.title.replace("/", "_").replace("\\", "_").strip() or page.id
                page_dir = per_page_root / safe
                page_dir.mkdir(parents=True, exist_ok=True)
                # page.md
                with (page_dir / "page.md").open("w", encoding="utf-8") as f:
                    f.write(f"# {page.title}\n\n")
                    f.write(page.content or "")
                # page.html
                with (page_dir / "page.html").open("w", encoding="utf-8") as f:
                    f.write("<!doctype html><html><head><meta charset='utf-8'>")
                    f.write(f"<title>{page.title}</title></head><body>\n")
                    f.write(f"<h1>{page.title}</h1>\n")
                    f.write(page.content or "")
                    f.write("\n</body></html>")
                # page.docx
                try:
                    from docx import Document
                    doc = Document()
                    doc.add_heading(page.title, level=1)
                    doc.add_paragraph(page.content or "")
                    doc.save(str(page_dir / "page.docx"))
                except Exception:
                    # If python-docx not available, skip
                    pass
                # attachments for page: try to copy from extract_dir/attachments/<page.id> or by title
                att_src_candidates = [
                    Path(extract_dir) / "attachments" / page.id,
                    Path(extract_dir) / "attachments" / page.title
                ]
                page_att_dir = page_dir / "attachments"
                page_att_dir.mkdir(parents=True, exist_ok=True)
                for cand in att_src_candidates:
                    if cand.exists() and cand.is_dir():
                        for f in cand.iterdir():
                            if f.is_file():
                                try:
                                    shutil.copy2(f, page_att_dir / f.name)
                                except Exception:
                                    pass

            # metadata.json
            with (out_dir / "metadata.json").open("w", encoding="utf-8") as mf:
                json.dump(meta, mf, indent=2)

            # Final ZIP naming
            sk = meta.get("space_key") or ""
            sn = meta.get("space_name") or ""
            ts = meta.get("generated_at")
            if sk and sn:
                fname = f"{sk} - {sn} - {ts}.zip"
            elif sn:
                fname = f"{sn} - {ts}.zip"
            else:
                fname = f"confluence-export-{ts}.zip"
            final_zip_path = OUTPUT_DIR / fname
            create_zip(str(out_dir), str(final_zip_path))

            JOBS[job_id]["status"] = "done"
            JOBS[job_id]["message"] = str(final_zip_path.name)
            JOBS[job_id]["path"] = str(final_zip_path)
            # Optionally clean up extracted data
            # shutil.rmtree(str(job_dir))
            return JSONResponse({"job_id": job_id})
        except Exception as e:
            logger = get_logger()
            logger.exception("Processing failed")
            JOBS[job_id]["status"] = "error"
            JOBS[job_id]["message"] = str(e)
            raise HTTPException(status_code=500, detail=f"Processing failed: {e}")
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@app.get("/status/{job_id}")
def status(job_id: str):
    if job_id not in JOBS:
        raise HTTPException(status_code=404, detail="Job not found")
    return JOBS[job_id]

@app.get("/download/{job_id}")
def download(job_id: str):
    if job_id not in JOBS:
        raise HTTPException(status_code=404, detail="Job not found")
    info = JOBS[job_id]
    if info.get("status") != "done":
        raise HTTPException(status_code=400, detail="Job not completed")
    path = info.get("path")
    if not path or not Path(path).exists():
        raise HTTPException(status_code=404, detail="Output not found")
    return FileResponse(path, filename=Path(path).name, media_type='application/zip')
EOF
}

write_main_py() {
    cat > "${PROJECT_ROOT}/app/main.py" <<'EOF'
import sys
from core.logger import get_logger
from core.config_loader import load_config
from pathlib import Path
from api.api import app as fastapi_app

logger = get_logger()

def run_ui():
    # This file is not used when running under uvicorn; kept for completeness
    import uvicorn
    uvicorn.run("api.api:app", host="0.0.0.0", port=8080, reload=False)

def main():
    if len(sys.argv) < 2:
        run_ui()
        return
    mode = sys.argv[1]
    if mode == "ui":
        run_ui()
    elif mode == "api":
        run_ui()
    else:
        logger.error(f"Unknown mode: {mode}")
        sys.exit(1)

if __name__ == "__main__":
    main()
EOF
}

write_ui_static() {
    # Copy index.html into static templates served by FastAPI via Jinja2 templates
    # We'll create a minimal template loader in api to serve this file at root.
    # Place static assets (none for now)
    :
}

write_api_root_route() {
    # Add a simple route to serve the UI page at /
    # Append to api/api.py: create a route to serve the template
    # We'll modify the file to include Jinja2 template serving
    python3 - <<'PY' || true
from pathlib import Path
p = Path("${PROJECT_ROOT}/app/api/api.py")
s = p.read_text()
if "from fastapi.responses import HTMLResponse" not in s:
    s = s.replace("from fastapi.responses import FileResponse, JSONResponse", "from fastapi.responses import FileResponse, JSONResponse, HTMLResponse")
if "from fastapi import FastAPI" in s and "from fastapi.templating import Jinja2Templates" not in s:
    s = s.replace("from fastapi import FastAPI", "from fastapi import FastAPI, Request")
    s = s.replace("logger = get_logger()", "logger = get_logger()\nfrom fastapi.templating import Jinja2Templates\nTEMPLATES = Jinja2Templates(directory='/app/ui/templates')")
if "app = FastAPI" in s and "def status(" in s:
    # insert root route before status
    insert_point = s.find("@app.get(\"/status/")
    if insert_point != -1:
        root_route = '''
@app.get("/", response_class=HTMLResponse)
def index(request: Request):
    return TEMPLATES.TemplateResponse("index.html", {"request": request})
'''
        s = s[:insert_point] + root_route + s[insert_point:]
p.write_text(s)
PY
}

build_image() {
    echo -e "${YELLOW}[INFO]${NC} Building Docker image ${IMAGE_NAME}..."
    (cd "${PROJECT_ROOT}" && docker build -t "${IMAGE_NAME}" -f docker/Dockerfile .)
    echo -e "${GREEN}[OK]${NC} Image built."
}

run_exporter_ui() {
    local config_path="${PROJECT_ROOT}/app/config.yaml"
    local output_dir="${OUTPUT_DIR}"
    mkdir -p "${output_dir}"

    echo -e "${YELLOW}[INFO]${NC} Starting UI container on port 8080..."
    echo "Open http://localhost:8080 in your browser."
docker run -d --name confluence-exporter-ui \
    -p 8080:8080 \
    -v "${PROJECT_ROOT}/app/output:/app/output" \
    -v "${PROJECT_ROOT}/app/tmp:/app/tmp" \
    -v "${PROJECT_ROOT}/app/ui/templates:/app/ui/templates" \
    -v "${PROJECT_ROOT}/app/logs:/app/logs" \
    "${IMAGE_NAME}" --ui
}

stop_exporter_ui() {
    if docker ps --format '{{.Names}}' | grep -q '^confluence-exporter-ui$'; then
        echo -e "${YELLOW}[INFO]${NC} Stopping UI container..."
        docker stop confluence-exporter-ui
        echo -e "${GREEN}[OK]${NC} UI stopped."
    else
        echo -e "${YELLOW}[INFO]${NC} UI is not running."
    fi
}

scaffold_everything() {
    prepare_project_root
    create_project_structure
    write_dockerfile
    write_requirements
    write_entrypoint
    write_config_yaml
    write_core_files
    write_parser_files
    write_transformers
    write_uploader_stub
    write_cli_stub
    write_ui_files
    write_api
    write_main_py
    write_ui_static
    write_api_root_route
    echo -e "${GREEN}[OK]${NC} Project scaffolded at ${PROJECT_ROOT}"
}

# Minimal stubs for uploader and cli to satisfy imports (no Box)
write_uploader_stub() {
    cat > "${PROJECT_ROOT}/app/uploader/box_client.py" <<'EOF'
# Box uploader removed for local-only pipeline. Stub kept for compatibility.
def get_box_client(config: dict):
    raise NotImplementedError("Box upload not supported in local-only mode.")
EOF

    cat > "${PROJECT_ROOT}/app/uploader/box_uploader.py" <<'EOF'
def upload_folder_to_box(config: dict, local_dir: str) -> None:
    raise NotImplementedError("Box upload not supported in local-only mode.")
EOF
}

write_cli_stub() {
    cat > "${PROJECT_ROOT}/app/cli/cli.py" <<'EOF'
# CLI removed in local-only UI mode. This stub exists for compatibility.
def main(argv=None):
    print("CLI mode is not supported in this build. Use the web UI at /")
EOF
}

targeted_cleanup() {
    echo -e "${YELLOW}[WARN]${NC} Targeted cleanup will remove:"
    echo "  - Docker image: ${IMAGE_NAME}"
    echo "  - Containers created from that image"
    echo "  - ${PROJECT_ROOT}"
    read -rp "Are you sure? (yes/no): " ans
    if [[ "${ans}" != "yes" ]]; then
        echo "Aborted."
        return
    fi

    echo -e "${YELLOW}[INFO]${NC} Stopping containers using image ${IMAGE_NAME}..."
    mapfile -t cids < <(docker ps -a --filter "ancestor=${IMAGE_NAME}" --format '{{.ID}}' || true)
    if [[ ${#cids[@]} -gt 0 ]]; then
        docker rm -f "${cids[@]}" || true
    fi

    echo -e "${YELLOW}[INFO]${NC} Removing image ${IMAGE_NAME}..."
    docker rmi "${IMAGE_NAME}" || true

    echo -e "${YELLOW}[INFO]${NC} Removing project directory ${PROJECT_ROOT}..."
    sudo rm -rf "${PROJECT_ROOT}"

    echo -e "${GREEN}[OK]${NC} Targeted cleanup complete."
}

nuclear_cleanup() {
    echo -e "${RED}[DANGER]${NC} Nuclear cleanup will:"
    echo "  - Remove ALL Docker containers"
    echo "  - Remove ALL Docker images"
    echo "  - Remove ALL Docker volumes"
    echo "  - Remove ALL Docker networks (non-default)"
    echo "  - Prune Docker system"
    echo "  - Remove ${PROJECT_ROOT}"
    echo
    read -rp "Type 'NUKE' to confirm: " ans
    if [[ "${ans}" != "NUKE" ]]; then
        echo "Aborted."
        return
    fi

    echo -e "${YELLOW}[INFO]${NC} Stopping all containers..."
    docker stop $(docker ps -q) 2>/dev/null || true

    echo -e "${YELLOW}[INFO]${NC} Removing all containers..."
    docker rm $(docker ps -aq) 2>/dev/null || true

    echo -e "${YELLOW}[INFO]${NC} Removing all images..."
    docker rmi $(docker images -q) 2>/dev/null || true

    echo -e "${YELLOW}[INFO]${NC} Removing all volumes..."
    docker volume rm $(docker volume ls -q) 2>/dev/null || true

    echo -e "${YELLOW}[INFO]${NC} Removing all networks (except default)..."
    docker network rm $(docker network ls -q | grep -vE '^(|bridge|host|none)$') 2>/dev/null || true

    echo -e "${YELLOW}[INFO]${NC} Pruning system..."
    docker system prune -a --volumes -f || true

    echo -e "${YELLOW}[INFO]${NC} Removing project directory ${PROJECT_ROOT}..."
    sudo rm -rf "${PROJECT_ROOT}"

    echo -e "${GREEN}[OK]${NC} Nuclear cleanup complete."
}

main_menu() {
    while true; do
        clear
        echo "=== ${APP_NAME} All-in-One Installer (confluence-exporter-installer.sh) ==="
        echo "1) Check environment"
        echo "2) Install Docker + prerequisites"
        echo "3) Ensure user in docker group"
        echo "4) Fix Docker permissions"
        echo "5) Verify Docker"
        echo "6) Scaffold project under /opt (write all files)"
        echo "7) Build Docker image"
        echo "8) Run confluence-exporter (UI)"
        echo "9) Stop confluence-exporter (UI)"
        echo "10) Targeted cleanup (project only)"
        echo "11) Nuclear cleanup (ALL Docker data + project)"
        echo "12) Exit"
        echo
        read -rp "Select an option: " choice

        case "$choice" in
            1)
                check_docker_installed || true
                if id -nG "$USER" | grep -qw docker; then
                    echo -e "${GREEN}[OK]${NC} User '$USER' is in docker group."
                else
                    echo -e "${YELLOW}[WARN]${NC} User '$USER' is NOT in docker group."
                fi
                pause
                ;;
            2)
                install_docker
                pause
                ;;
            3)
                ensure_docker_group
                pause
                ;;
            4)
                fix_docker_permissions
                pause
                ;;
            5)
                verify_docker
                pause
                ;;
            6)
                scaffold_everything
                pause
                ;;
            7)
                build_image
                pause
                ;;
            8)
                run_exporter_ui
                pause
                ;;
            9)
                stop_exporter_ui
                pause
                ;;
            10)
                targeted_cleanup
                pause
                ;;
            11)
                nuclear_cleanup
                pause
                ;;
            12)
                exit 0
                ;;
            *)
                echo -e "${RED}[ERROR]${NC} Invalid choice."
                pause
                ;;
        esac
    done
}

# Ensure helper functions exist before calling main_menu
# Some write_* functions referenced earlier are defined as shell functions; ensure they exist
# (they are defined above). Now run the menu.
main_menu
