# Single Agent Template

A simple ADK agent template with custom tools.

## Setup

1. Install dependencies:
```bash
pip install -r requirements.txt
```

2. Set up environment variables:
```bash
cp .env.example .env
# Edit .env and add your GOOGLE_AI_API_KEY
```

## Usage

### CLI Mode
```bash
python agent.py
```

### Web UI Mode
```bash
adk ui --agent-file agent.py
```

### Programmatic Usage
```python
from agent import root_agent

result = root_agent.run("Search for user data")
print(result.output)
```

## Customization

1. **Add Tools**: Define new functions and wrap them with `Tool()`
2. **Update Instruction**: Modify the agent's instruction to reflect new capabilities
3. **Change Model**: Update `model` parameter to use different Gemini models
4. **Add Configuration**: Extend with config files for production settings

## Deployment

See [adk-deployment.md](../../../references/adk-deployment.md) for deployment options.
