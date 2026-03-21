# ADK Best Practices

Best practices for building production-ready multi-agent systems with Google's Agent Development Kit.

## Agent Design Principles

### 1. Agent Descriptions Are Critical

Agent descriptions act as "API documentation for the LLM" in coordinator patterns.

**Bad Example:**
```python
billing_agent = LlmAgent(
    name="BillingAgent",
    description="Handles billing."  # Too vague
)
```

**Good Example:**
```python
billing_agent = LlmAgent(
    name="BillingAgent",
    description="Handles billing inquiries, invoice generation, payment processing, refunds, and subscription management."  # Specific capabilities
)
```

**Guidelines:**
- Be specific about what the agent does
- List key capabilities and tools
- Help the coordinator make correct routing decisions
- Include constraints (e.g., "for US customers only")

### 2. Use Descriptive output_key Values

State keys should be self-documenting.

**Bad Example:**
```python
parser = LlmAgent(
    output_key="data"  # Ambiguous
)
```

**Good Example:**
```python
parser = LlmAgent(
    output_key="parsed_pdf_text"  # Clear and specific
)
```

**Guidelines:**
- Use snake_case for consistency
- Include data type or source hint
- Make keys grep-friendly for debugging
- Avoid generic names like "result", "output", "data"

### 3. Avoid Race Conditions in Parallel Execution

ParallelAgent runs sub-agents in separate threads sharing session.state.

**Bad Example:**
```python
# Both agents write to same key - race condition!
agent1 = LlmAgent(output_key="result")
agent2 = LlmAgent(output_key="result")
parallel = ParallelAgent(sub_agents=[agent1, agent2])
```

**Good Example:**
```python
# Each agent writes to unique key
security = LlmAgent(output_key="security_report")
style = LlmAgent(output_key="style_report")
parallel = ParallelAgent(sub_agents=[security, style])
```

**Guidelines:**
- Each parallel agent must have unique output_key
- Aggregation step combines results after parallel execution
- Consider using namespaced keys (e.g., "parallel_task_1_result")

## State Management

### 1. Shared Session State

All agents in a workflow share `session.state` - a dict-like object.

**Reading State:**
```python
agent = LlmAgent(
    instruction="Summarize the content in {parsed_text}."  # Reads from state
)
```

**Writing State:**
```python
agent = LlmAgent(
    output_key="summary"  # Writes to state["summary"]
)
```

**Guidelines:**
- State is the "digital whiteboard" for agent communication
- Use template variables `{key_name}` to read from state
- Set `output_key` to write final result to state
- State persists across the entire session

### 2. Early Exit from Workflows

Agents can signal completion early using `escalate=True`.

```python
from adk.events import EventActions

def check_cache(session):
    if cache.has(session.user_input):
        return EventActions(
            output=cache.get(session.user_input),
            escalate=True  # Skip remaining agents
        )
    return EventActions()

cache_agent = CustomAgent(
    name="CacheAgent",
    on_run=check_cache
)
```

**Guidelines:**
- Use for optimization (cache hits, early validation failures)
- Clear logging when escalating
- Document escalation conditions

## Tool Integration

### 1. Tool Naming Conventions

```python
from adk.tools import Tool

# Good: Verb-noun pattern, clear purpose
get_weather_tool = Tool(
    name="get_weather",
    description="Retrieve current weather for a location.",
    function=get_weather_data
)

# Bad: Vague naming
weather = Tool(
    name="weather",  # Ambiguous - get? set? forecast?
    description="Weather.",
    function=weather_fn
)
```

### 2. Tool Confirmation Flow

For high-stakes operations, require human confirmation.

```python
from adk.tools import ToolExecutionMode

delete_tool = Tool(
    name="delete_database",
    description="Permanently delete database. REQUIRES CONFIRMATION.",
    function=delete_db,
    execution_mode=ToolExecutionMode.REQUIRE_CONFIRMATION
)

agent = LlmAgent(
    tools=[delete_tool],
    instruction="Never delete databases without explicit user approval."
)
```

**Guidelines:**
- Use REQUIRE_CONFIRMATION for irreversible actions
- Document which tools require confirmation
- Provide clear context in confirmation prompts

### 3. Custom Tools vs. Built-in Tools

ADK provides built-in tools for common operations:

```python
from adk.tools import GoogleSearch, CodeExecution, ImageGeneration

# Use built-in when available
agent = LlmAgent(
    tools=[GoogleSearch()]  # Optimized, maintained
)
```

**When to Build Custom Tools:**
- Domain-specific operations
- Internal API integrations
- Custom data sources
- Proprietary business logic

## Error Handling

### 1. Graceful Degradation

```python
primary_agent = LlmAgent(
    name="PrimaryAgent",
    instruction="Try to complete task. If you encounter errors, document them in {error_log}.",
    output_key="result"
)

fallback_agent = LlmAgent(
    name="FallbackAgent",
    instruction="If {result} indicates failure, attempt alternative approach.",
    output_key="final_result"
)

workflow = SequentialAgent(sub_agents=[primary_agent, fallback_agent])
```

### 2. Max Iterations for Loops

Always set `max_iterations` to prevent infinite loops.

```python
# Bad: No max_iterations
loop = LoopAgent(
    sub_agents=[generator, critic],
    exit_condition="PASS"
)

# Good: Safety limit
loop = LoopAgent(
    sub_agents=[generator, critic],
    exit_condition="PASS",
    max_iterations=5  # Prevent runaway costs
)
```

### 3. Tool Error Handling

```python
from adk.tools import Tool

def safe_api_call(params):
    try:
        return external_api.call(params)
    except Exception as e:
        return {
            "error": str(e),
            "status": "failed",
            "fallback_available": True
        }

api_tool = Tool(
    name="external_api",
    function=safe_api_call
)
```

## Performance Optimization

### 1. Model Selection

Choose appropriate models for each agent's complexity.

```python
# Simple routing - use fast model
coordinator = LlmAgent(
    model="gemini-2.0-flash-lite",  # Fast, cheap
    instruction="Route to appropriate specialist."
)

# Complex analysis - use powerful model
analyst = LlmAgent(
    model="gemini-2.5-pro",  # Powerful, slower
    instruction="Perform deep code analysis..."
)
```

**Model Selection Guide:**
- `gemini-2.0-flash-lite`: Simple routing, classification
- `gemini-2.0-flash`: General purpose, balanced
- `gemini-2.5-pro`: Complex reasoning, analysis

### 2. Minimize Context Window Usage

```python
# Bad: Passing entire document repeatedly
agent = LlmAgent(
    instruction="Analyze this document: {full_document_text}"
)

# Good: Extract relevant section first
extractor = LlmAgent(
    instruction="Extract relevant sections from {full_document_text}.",
    output_key="relevant_sections"
)

analyzer = LlmAgent(
    instruction="Analyze {relevant_sections}."
)
```

### 3. Parallel Execution for Independent Tasks

```python
# Bad: Sequential when tasks are independent
workflow = SequentialAgent(
    sub_agents=[security_check, style_check, performance_check]
)

# Good: Parallel for independent tasks
parallel_checks = ParallelAgent(
    sub_agents=[security_check, style_check, performance_check]
)
```

## Code Organization

### 1. Project Structure

Recommended structure for ADK projects:

```
my_agent_project/
├── agent.py              # Main agent definition (root_agent)
├── agents/              # Agent module definitions
│   ├── __init__.py
│   ├── specialists.py   # Specialist agents
│   ├── coordinators.py  # Coordinator agents
│   └── workflows.py     # Workflow agents
├── tools/               # Custom tool definitions
│   ├── __init__.py
│   ├── data_tools.py
│   └── api_tools.py
├── config/              # Configuration
│   ├── __init__.py
│   └── settings.py
├── tests/               # Tests
│   └── test_agents.py
├── requirements.txt
└── README.md
```

### 2. Agent Modularity

Create reusable agent components.

```python
# agents/specialists.py
def create_billing_specialist():
    return LlmAgent(
        name="BillingSpecialist",
        description="Handles billing and payments.",
        tools=[BillingDB, PaymentProcessor]
    )

def create_tech_support():
    return LlmAgent(
        name="TechSupport",
        description="Handles technical issues.",
        tools=[KnowledgeBase, TicketSystem]
    )

# agent.py
from agents.specialists import create_billing_specialist, create_tech_support

root_agent = LlmAgent(
    name="CustomerSupportBot",
    sub_agents=[
        create_billing_specialist(),
        create_tech_support()
    ]
)
```

### 3. Configuration Management

Externalize configuration for flexibility.

```python
# config/settings.py
from pydantic import BaseSettings

class Settings(BaseSettings):
    model_name: str = "gemini-2.0-flash"
    max_iterations: int = 5
    enable_logging: bool = True
    api_key: str

    class Config:
        env_file = ".env"

settings = Settings()

# agent.py
from config.settings import settings

agent = LlmAgent(
    model=settings.model_name,
    max_iterations=settings.max_iterations
)
```

## Testing and Evaluation

### 1. Unit Testing Agents

```python
# tests/test_agents.py
import pytest
from adk.testing import MockSession

def test_billing_specialist():
    agent = create_billing_specialist()
    session = MockSession(
        user_input="What's my current balance?",
        state={"user_id": "12345"}
    )

    result = agent.run(session)

    assert "balance" in result.output.lower()
    assert session.state.get("billing_query_complete") == True
```

### 2. Integration Testing

```python
def test_full_workflow():
    workflow = SequentialAgent(
        sub_agents=[parser, extractor, summarizer]
    )

    session = MockSession(
        user_input="Analyze document.pdf"
    )

    result = workflow.run(session)

    assert session.state.get("parsed_pdf_text") is not None
    assert session.state.get("structured_data") is not None
    assert result.output is not None
```

### 3. Evaluation with ADK CLI

```bash
# Evaluate agent performance
adk eval --agent-file agent.py --test-set test_cases.json

# Generate evaluation report
adk eval --agent-file agent.py --test-set test_cases.json --output report.html
```

## Security Best Practices

### 1. Input Validation

```python
def validate_input(user_input: str) -> bool:
    # Check for malicious patterns
    forbidden_patterns = ["DROP TABLE", "rm -rf", "DELETE FROM"]
    return not any(p in user_input.upper() for p in forbidden_patterns)

agent = LlmAgent(
    instruction="First validate {user_input} is safe, then proceed.",
    tools=[ValidationTool(validate_input)]
)
```

### 2. API Key Management

```python
# Bad: Hardcoded secrets
agent = LlmAgent(
    model="gemini-2.0-flash",
    api_key="AIza..."  # Never do this!
)

# Good: Environment variables
import os

agent = LlmAgent(
    model="gemini-2.0-flash",
    api_key=os.getenv("GOOGLE_AI_API_KEY")
)
```

### 3. Rate Limiting

```python
from functools import lru_cache
import time

@lru_cache(maxsize=100)
def rate_limited_tool(query: str):
    time.sleep(0.1)  # Simple rate limit
    return external_api.call(query)
```

## Monitoring and Observability

### 1. Logging

```python
import logging

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

agent = LlmAgent(
    name="MyAgent",
    on_start=lambda s: logger.info(f"Agent starting: {s.user_input}"),
    on_complete=lambda s: logger.info(f"Agent complete: {s.state}")
)
```

### 2. Tracing

ADK provides built-in tracing for debugging.

```python
# Enable tracing
import os
os.environ["ADK_TRACE"] = "true"

# Traces will show:
# - Agent execution order
# - State changes
# - Tool calls
# - LLM prompts and responses
```

### 3. Analytics

```python
from adk.analytics import track_event

def track_completion(session):
    track_event(
        event="agent_completion",
        properties={
            "agent_name": session.current_agent.name,
            "duration": session.duration,
            "tokens_used": session.total_tokens
        }
    )
```

## Common Pitfalls to Avoid

### 1. Over-Engineering

**Bad:**
```python
# Too many layers for simple task
coordinator = LlmAgent(
    sub_agents=[
        LlmAgent(sub_agents=[
            LlmAgent(sub_agents=[simple_task])
        ])
    ]
)
```

**Good:**
```python
# Simple task = simple agent
simple_agent = LlmAgent(
    instruction="Complete simple task.",
    tools=[SimpleTool]
)
```

### 2. Ignoring Cost Management

**Bad:**
```python
# Unlimited iterations with expensive model
loop = LoopAgent(
    model="gemini-2.5-pro",  # Expensive
    sub_agents=[generator, critic]
    # No max_iterations!
)
```

**Good:**
```python
# Cost-conscious design
loop = LoopAgent(
    model="gemini-2.0-flash",  # Cheaper for iteration
    sub_agents=[generator, critic],
    max_iterations=3  # Limit cost
)
```

### 3. Poor Error Messages

**Bad:**
```python
if validation_failed:
    return "Error"  # Unhelpful
```

**Good:**
```python
if validation_failed:
    return {
        "status": "error",
        "message": "Validation failed: email format invalid",
        "field": "email",
        "suggestion": "Use format: user@example.com"
    }
```

## References

- [ADK Python Documentation](https://google.github.io/adk-docs/get-started/python/)
- [Multi-Agent Patterns](https://developers.googleblog.com/developers-guide-to-multi-agent-patterns-in-adk/)
- [ADK GitHub Repository](https://github.com/google/adk-python)
