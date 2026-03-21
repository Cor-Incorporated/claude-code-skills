# Multi-Agent System Template

A coordinator agent with multiple specialist sub-agents demonstrating the Coordinator/Dispatcher pattern.

## Architecture

```
CoordinatorAgent (root)
├── DataSpecialist
│   └── Handles data fetching
├── AnalysisSpecialist
│   └── Performs analysis
└── ReportSpecialist
    └── Generates reports
```

## How It Works

1. **User Request** → Coordinator analyzes intent
2. **Delegation** → Coordinator routes to appropriate specialist(s)
3. **Execution** → Specialist(s) perform their tasks
4. **Response** → Coordinator returns results to user

## Setup

1. Install dependencies:
```bash
pip install -r requirements.txt
```

2. Set environment variables:
```bash
export GOOGLE_AI_API_KEY=your_api_key_here
```

## Usage

### CLI Mode
```bash
python agent.py
```

Example queries:
- "Fetch data for user 12345"
- "Analyze the latest sales data"
- "Generate a report on Q4 performance"

### Web UI Mode
```bash
adk ui --agent-file agent.py
```

### Programmatic Usage
```python
from agent import root_agent

result = root_agent.run("Generate a report on user activity")
print(result.output)
```

## Customization

### Add New Specialist

```python
# 1. Create specialist agent
new_specialist = LlmAgent(
    name="NewSpecialist",
    description="Clear description of what this specialist does",
    instruction="Detailed instructions for the specialist",
    tools=[...],
)

# 2. Add to coordinator's sub_agents
root_agent = LlmAgent(
    sub_agents=[
        data_specialist,
        analysis_specialist,
        report_specialist,
        new_specialist,  # Add here
    ],
)

# 3. Update coordinator instruction to mention new specialist
```

### Modify Specialist Behavior

Edit the specialist's:
- `description`: How coordinator routes to it
- `instruction`: How it performs its tasks
- `tools`: What capabilities it has

## Design Patterns Used

- **Coordinator/Dispatcher**: Root agent routes to specialists
- **Shared State**: Specialists communicate via `session.state`
- **LLM-Driven Routing**: Automatic delegation based on intent

## Deployment

See [adk-deployment.md](../../../references/adk-deployment.md) for deployment options.
