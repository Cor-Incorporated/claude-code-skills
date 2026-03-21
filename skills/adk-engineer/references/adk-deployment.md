# ADK Deployment Guide

Guide for deploying ADK agents to production environments.

## Deployment Options

ADK supports three main deployment targets:

1. **Vertex AI Agent Engine** - Fully managed, production-ready (Recommended)
2. **Cloud Run** - Containerized deployment with auto-scaling
3. **Local/Custom** - Docker containers for on-premise or custom cloud

## Vertex AI Agent Engine Deployment

### Prerequisites

```bash
# Install Google Cloud SDK
curl https://sdk.cloud.google.com | bash
exec -l $SHELL

# Authenticate
gcloud auth login
gcloud config set project YOUR_PROJECT_ID

# Install ADK
pip install google-adk
```

### Deployment Steps

**1. Prepare Your Agent**

```python
# agent.py
from adk.agents import LlmAgent

root_agent = LlmAgent(
    name="ProductionAgent",
    model="gemini-2.0-flash",
    instruction="Handle customer queries professionally.",
    tools=[...]
)
```

**2. Deploy to Agent Engine**

```bash
# Deploy to Vertex AI Agent Engine
adk deploy agent_engine \
  --project=YOUR_PROJECT_ID \
  --region=us-central1 \
  --staging_bucket=gs://YOUR_BUCKET/staging \
  --agent-file=agent.py
```

**3. Verify Deployment**

```bash
# List deployments
adk deploy list --project=YOUR_PROJECT_ID

# Test deployed agent
adk deploy test \
  --deployment-id=YOUR_DEPLOYMENT_ID \
  --input="Hello, how can you help?"
```

### Configuration Options

```bash
# Full deployment with custom settings
adk deploy agent_engine \
  --project=YOUR_PROJECT_ID \
  --region=us-central1 \
  --staging_bucket=gs://YOUR_BUCKET/staging \
  --agent-file=agent.py \
  --service-account=YOUR_SERVICE_ACCOUNT@PROJECT.iam.gserviceaccount.com \
  --memory=2Gi \
  --cpu=2 \
  --min-instances=1 \
  --max-instances=10
```

### Environment Variables

```bash
# Set environment variables for deployed agent
adk deploy agent_engine \
  --project=YOUR_PROJECT_ID \
  --env-vars="API_KEY=secret123,LOG_LEVEL=INFO"
```

## Cloud Run Deployment

### Using ADK CLI

```bash
# Deploy to Cloud Run
adk deploy cloud_run \
  --project=YOUR_PROJECT_ID \
  --region=us-central1 \
  --agent-file=agent.py \
  --service-name=my-agent-service
```

### Manual Deployment

**1. Create Dockerfile**

```dockerfile
# Dockerfile
FROM python:3.11-slim

WORKDIR /app

# Install dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy agent code
COPY agent.py .
COPY tools/ tools/
COPY agents/ agents/

# Expose port
EXPOSE 8080

# Run agent server
CMD ["python", "-m", "adk.server", "--agent-file=agent.py", "--port=8080"]
```

**2. Build and Push Container**

```bash
# Build container
docker build -t gcr.io/YOUR_PROJECT_ID/my-agent:latest .

# Configure Docker for GCR
gcloud auth configure-docker

# Push to Google Container Registry
docker push gcr.io/YOUR_PROJECT_ID/my-agent:latest
```

**3. Deploy to Cloud Run**

```bash
gcloud run deploy my-agent-service \
  --image=gcr.io/YOUR_PROJECT_ID/my-agent:latest \
  --platform=managed \
  --region=us-central1 \
  --allow-unauthenticated \
  --memory=2Gi \
  --cpu=2 \
  --min-instances=1 \
  --max-instances=10 \
  --set-env-vars="API_KEY=secret123,LOG_LEVEL=INFO"
```

**4. Test Deployment**

```bash
# Get service URL
SERVICE_URL=$(gcloud run services describe my-agent-service \
  --platform=managed \
  --region=us-central1 \
  --format='value(status.url)')

# Test endpoint
curl -X POST $SERVICE_URL/query \
  -H "Content-Type: application/json" \
  -d '{"input": "Hello, how can you help?"}'
```

## Docker Deployment (Local/Custom)

### Create Production Dockerfile

```dockerfile
FROM python:3.11-slim

# Install system dependencies
RUN apt-get update && apt-get install -y \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Install Python dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy application code
COPY . .

# Create non-root user
RUN useradd -m -u 1000 agent && chown -R agent:agent /app
USER agent

# Health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD python -c "import requests; requests.get('http://localhost:8080/health')"

EXPOSE 8080

CMD ["python", "-m", "adk.server", "--agent-file=agent.py", "--port=8080", "--host=0.0.0.0"]
```

### Docker Compose Setup

```yaml
# docker-compose.yml
version: '3.8'

services:
  agent:
    build: .
    ports:
      - "8080:8080"
    environment:
      - API_KEY=${API_KEY}
      - LOG_LEVEL=INFO
      - ENVIRONMENT=production
    volumes:
      - ./data:/app/data
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8080/health"]
      interval: 30s
      timeout: 3s
      retries: 3
    deploy:
      resources:
        limits:
          cpus: '2'
          memory: 2G
        reservations:
          cpus: '1'
          memory: 1G

  # Optional: Redis for session storage
  redis:
    image: redis:7-alpine
    ports:
      - "6379:6379"
    volumes:
      - redis_data:/data
    restart: unless-stopped

volumes:
  redis_data:
```

### Run with Docker Compose

```bash
# Build and start
docker-compose up -d

# View logs
docker-compose logs -f agent

# Scale instances
docker-compose up -d --scale agent=3

# Stop
docker-compose down
```

## CI/CD Integration

### GitHub Actions Example

```yaml
# .github/workflows/deploy.yml
name: Deploy ADK Agent

on:
  push:
    branches: [ main ]

jobs:
  deploy:
    runs-on: ubuntu-latest

    steps:
    - uses: actions/checkout@v3

    - name: Set up Python
      uses: actions/setup-python@v4
      with:
        python-version: '3.11'

    - name: Install dependencies
      run: |
        pip install google-adk
        pip install -r requirements.txt

    - name: Run tests
      run: |
        pytest tests/

    - name: Authenticate to Google Cloud
      uses: google-github-actions/auth@v1
      with:
        credentials_json: ${{ secrets.GCP_CREDENTIALS }}

    - name: Deploy to Vertex AI Agent Engine
      run: |
        adk deploy agent_engine \
          --project=${{ secrets.GCP_PROJECT_ID }} \
          --region=us-central1 \
          --staging_bucket=gs://${{ secrets.STAGING_BUCKET }}/staging \
          --agent-file=agent.py
```

### GitLab CI Example

```yaml
# .gitlab-ci.yml
stages:
  - test
  - build
  - deploy

variables:
  IMAGE: gcr.io/$GCP_PROJECT_ID/my-agent
  GCP_REGION: us-central1

test:
  stage: test
  image: python:3.11
  script:
    - pip install -r requirements.txt
    - pytest tests/

build:
  stage: build
  image: google/cloud-sdk:latest
  services:
    - docker:dind
  script:
    - echo $GCP_SERVICE_KEY | base64 -d > ${HOME}/gcp-key.json
    - gcloud auth activate-service-account --key-file ${HOME}/gcp-key.json
    - gcloud config set project $GCP_PROJECT_ID
    - gcloud auth configure-docker
    - docker build -t $IMAGE:$CI_COMMIT_SHA .
    - docker push $IMAGE:$CI_COMMIT_SHA
    - docker tag $IMAGE:$CI_COMMIT_SHA $IMAGE:latest
    - docker push $IMAGE:latest

deploy:
  stage: deploy
  image: google/cloud-sdk:latest
  script:
    - echo $GCP_SERVICE_KEY | base64 -d > ${HOME}/gcp-key.json
    - gcloud auth activate-service-account --key-file ${HOME}/gcp-key.json
    - gcloud config set project $GCP_PROJECT_ID
    - gcloud run deploy my-agent-service
        --image=$IMAGE:$CI_COMMIT_SHA
        --platform=managed
        --region=$GCP_REGION
        --allow-unauthenticated
  only:
    - main
```

## Production Best Practices

### 1. Environment Configuration

```python
# config/production.py
import os
from pydantic import BaseSettings

class ProductionSettings(BaseSettings):
    # API Keys
    google_ai_api_key: str
    external_api_key: str

    # Deployment
    environment: str = "production"
    log_level: str = "INFO"

    # Performance
    max_concurrent_requests: int = 100
    request_timeout: int = 30

    # Monitoring
    enable_tracing: bool = True
    enable_metrics: bool = True

    class Config:
        env_file = ".env.production"

settings = ProductionSettings()
```

### 2. Logging and Monitoring

```python
# agent.py
import logging
from google.cloud import logging as cloud_logging

# Configure Cloud Logging
client = cloud_logging.Client()
client.setup_logging()

logger = logging.getLogger(__name__)
logger.setLevel(logging.INFO)

root_agent = LlmAgent(
    name="ProductionAgent",
    on_start=lambda s: logger.info(f"Request started: {s.user_input}"),
    on_complete=lambda s: logger.info(f"Request completed: {s.state}"),
    on_error=lambda s, e: logger.error(f"Error: {e}", exc_info=True)
)
```

### 3. Health Checks

```python
# health.py
from fastapi import FastAPI
from adk.server import ADKServer

app = FastAPI()
adk_server = ADKServer(agent_file="agent.py")

@app.get("/health")
def health_check():
    return {
        "status": "healthy",
        "agent": "running",
        "version": "1.0.0"
    }

@app.get("/ready")
def readiness_check():
    # Check if agent is ready to serve requests
    try:
        adk_server.get_agent()
        return {"status": "ready"}
    except Exception as e:
        return {"status": "not_ready", "error": str(e)}, 503
```

### 4. Rate Limiting

```python
# middleware/rate_limit.py
from fastapi import Request, HTTPException
from slowapi import Limiter
from slowapi.util import get_remote_address

limiter = Limiter(key_func=get_remote_address)

@app.post("/query")
@limiter.limit("10/minute")
async def query(request: Request, input_data: dict):
    # Process request
    return adk_server.process(input_data)
```

### 5. Secrets Management

**Using Google Secret Manager:**

```python
# utils/secrets.py
from google.cloud import secretmanager

def get_secret(secret_id: str, project_id: str) -> str:
    client = secretmanager.SecretManagerServiceClient()
    name = f"projects/{project_id}/secrets/{secret_id}/versions/latest"
    response = client.access_secret_version(request={"name": name})
    return response.payload.data.decode("UTF-8")

# Usage in agent.py
api_key = get_secret("external-api-key", "my-project-id")
```

### 6. Autoscaling Configuration

**Cloud Run Autoscaling:**

```bash
gcloud run services update my-agent-service \
  --min-instances=2 \
  --max-instances=100 \
  --concurrency=80 \
  --cpu-throttling \
  --memory=2Gi
```

## Monitoring and Observability

### Cloud Monitoring

```python
# monitoring/metrics.py
from google.cloud import monitoring_v3
import time

def record_request_duration(duration_ms: float):
    client = monitoring_v3.MetricServiceClient()
    project_name = f"projects/{PROJECT_ID}"

    series = monitoring_v3.TimeSeries()
    series.metric.type = "custom.googleapis.com/agent/request_duration"
    series.resource.type = "cloud_run_revision"

    point = monitoring_v3.Point()
    point.value.double_value = duration_ms
    point.interval.end_time.seconds = int(time.time())

    series.points = [point]
    client.create_time_series(name=project_name, time_series=[series])
```

### Tracing with OpenTelemetry

```python
# monitoring/tracing.py
from opentelemetry import trace
from opentelemetry.exporter.cloud_trace import CloudTraceSpanExporter
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor

trace.set_tracer_provider(TracerProvider())
tracer = trace.get_tracer(__name__)

cloud_trace_exporter = CloudTraceSpanExporter()
trace.get_tracer_provider().add_span_processor(
    BatchSpanProcessor(cloud_trace_exporter)
)

# Use in agent
with tracer.start_as_current_span("agent_execution"):
    result = root_agent.run(session)
```

## Rollback Strategy

### Blue-Green Deployment

```bash
# Deploy new version (green)
gcloud run deploy my-agent-service-green \
  --image=gcr.io/PROJECT/my-agent:v2 \
  --no-traffic

# Test green deployment
curl https://my-agent-service-green-hash.run.app/health

# Switch traffic gradually
gcloud run services update-traffic my-agent-service \
  --to-revisions=my-agent-service-green=10

# Monitor, then complete rollout
gcloud run services update-traffic my-agent-service \
  --to-revisions=my-agent-service-green=100

# Rollback if needed
gcloud run services update-traffic my-agent-service \
  --to-revisions=my-agent-service-blue=100
```

## Cost Optimization

### 1. Model Selection

```python
# Use cheaper models for routing
coordinator = LlmAgent(
    model="gemini-2.0-flash-lite",  # Cheaper
    instruction="Route to specialist."
)

# Use expensive models only when necessary
specialist = LlmAgent(
    model="gemini-2.5-pro",  # Only for complex tasks
    instruction="Perform deep analysis."
)
```

### 2. Caching

```python
from functools import lru_cache

@lru_cache(maxsize=1000)
def get_cached_response(query: str):
    return agent.run(query)
```

### 3. Request Batching

```python
# Process multiple requests in batch
def batch_process(queries: list[str]):
    return [agent.run(q) for q in queries]
```

## Security Checklist

- [ ] API keys stored in Secret Manager
- [ ] Service account with minimal permissions
- [ ] VPC Service Controls enabled
- [ ] SSL/TLS encryption enforced
- [ ] Input validation implemented
- [ ] Rate limiting configured
- [ ] Logging and monitoring enabled
- [ ] Regular security audits scheduled

## References

- [Vertex AI Agent Engine Documentation](https://cloud.google.com/vertex-ai/generative-ai/docs/agent-development-kit/quickstart)
- [Cloud Run Documentation](https://cloud.google.com/run/docs)
- [ADK Deployment Guide](https://docs.cloud.google.com/agent-builder/agent-development-kit/overview)
