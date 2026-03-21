# ADK Design Patterns

This document describes the 7 essential design patterns for building multi-agent systems with Google's Agent Development Kit (ADK).

## 1. Sequential Pipeline Pattern

**Use Case:** Linear data processing workflows where each step depends on the previous one.

**When to Use:**
- Data transformation pipelines
- Document processing workflows
- Step-by-step analysis tasks

**Implementation:**

```python
from adk.agents import LlmAgent, SequentialAgent

# Define individual agents
parser = LlmAgent(
    name="ParserAgent",
    instruction="Parse raw PDF and extract text.",
    tools=[PDFParser],
    output_key="raw_text"
)

extractor = LlmAgent(
    name="ExtractorAgent",
    instruction="Extract structured data from {raw_text}.",
    tools=[RegexExtractor],
    output_key="structured_data"
)

summarizer = LlmAgent(
    name="SummarizerAgent",
    instruction="Generate summary from {structured_data}.",
    tools=[SummaryEngine]
)

# Compose into sequential pipeline
pipeline = SequentialAgent(
    name="PDFProcessingPipeline",
    sub_agents=[parser, extractor, summarizer]
)
```

**Key Points:**
- Linear execution: Agent A → Agent B → Agent C
- Each agent reads from and writes to session.state
- Use descriptive `output_key` values for clarity
- Deterministic and easy to debug

## 2. Coordinator/Dispatcher Pattern

**Use Case:** Intent-based routing to specialist agents.

**When to Use:**
- Customer service systems
- Multi-domain task handling
- Dynamic agent selection based on context

**Implementation:**

```python
# Define specialist agents
billing_specialist = LlmAgent(
    name="BillingSpecialist",
    description="Handles billing inquiries, invoices, and payment issues.",
    tools=[BillingSystemDB]
)

tech_support = LlmAgent(
    name="TechSupport",
    description="Handles technical issues, troubleshooting, and setup.",
    tools=[TechKnowledgeBase]
)

# Coordinator agent with LLM-driven routing
coordinator = LlmAgent(
    name="CoordinatorAgent",
    instruction="Analyze user intent and route to the appropriate specialist.",
    sub_agents=[billing_specialist, tech_support]
)
```

**Key Points:**
- Parent agent analyzes intent and delegates
- Agent descriptions are crucial (they're "API documentation for the LLM")
- ADK's AutoFlow handles execution transfer
- No explicit routing logic needed

## 3. Parallel Fan-Out/Gather Pattern

**Use Case:** Concurrent task execution with result aggregation.

**When to Use:**
- Independent tasks that can run simultaneously
- Code review (security, style, performance checks)
- Multi-source data gathering

**Implementation:**

```python
from adk.agents import ParallelAgent

# Define parallel workers
security_scanner = LlmAgent(
    name="SecurityAuditor",
    instruction="Check for vulnerabilities like injection attacks.",
    output_key="security_report"
)

style_checker = LlmAgent(
    name="StyleEnforcer",
    instruction="Check for PEP8 compliance and formatting issues.",
    output_key="style_report"
)

performance_analyzer = LlmAgent(
    name="PerformanceAnalyzer",
    instruction="Identify performance bottlenecks and optimization opportunities.",
    output_key="performance_report"
)

# Run in parallel
parallel_reviews = ParallelAgent(
    name="CodeReviewSwarm",
    sub_agents=[security_scanner, style_checker, performance_analyzer]
)

# Aggregate results
pr_summarizer = LlmAgent(
    name="PRSummarizer",
    instruction="Create consolidated review using {security_report}, {style_report}, and {performance_report}."
)

# Complete workflow
workflow = SequentialAgent(
    sub_agents=[parallel_reviews, pr_summarizer]
)
```

**Key Points:**
- Agents execute concurrently in separate threads
- Each agent must write to unique `output_key` to avoid race conditions
- Shared session.state for communication
- Followed by aggregation step

## 4. Hierarchical Decomposition Pattern

**Use Case:** Complex tasks broken into nested subtasks.

**When to Use:**
- Research and analysis projects
- Content creation with multiple research steps
- Tasks requiring specialized sub-workflows

**Implementation:**

```python
from adk.tools import AgentTool

# Level 2: Specialist agents
web_searcher = LlmAgent(
    name="WebSearchAgent",
    description="Searches web for facts and data.",
    tools=[GoogleSearch]
)

summarizer = LlmAgent(
    name="SummarizerAgent",
    description="Condenses long text into key points.",
    tools=[TextProcessor]
)

# Level 1: Mid-level coordinator
research_assistant = LlmAgent(
    name="ResearchAssistant",
    description="Finds and summarizes information on any topic.",
    sub_agents=[web_searcher, summarizer]
)

# Level 0: Top-level agent
report_writer = LlmAgent(
    name="ReportWriter",
    instruction="Write comprehensive report. Use ResearchAssistant to gather information.",
    tools=[AgentTool(research_assistant)]
)
```

**Key Points:**
- Tree structure with parent-child relationships
- Each level handles appropriate abstraction
- Can call sub-agents as tools via AgentTool
- Enables modular reuse of agent hierarchies

## 5. Generator and Critic Pattern

**Use Case:** Draft generation with validation loops until quality criteria met.

**When to Use:**
- Code generation with syntax validation
- SQL query generation with validation
- Content generation requiring fact-checking

**Implementation:**

```python
from adk.agents import LoopAgent

generator = LlmAgent(
    name="Generator",
    instruction="Generate a SQL query. If you receive {feedback}, fix the errors.",
    output_key="draft"
)

critic = LlmAgent(
    name="Critic",
    instruction="Check if {draft} is valid SQL. Output 'PASS' if valid, otherwise describe errors.",
    output_key="feedback"
)

validation_loop = LoopAgent(
    name="ValidationLoop",
    sub_agents=[generator, critic],
    condition_key="feedback",
    exit_condition="PASS"
)
```

**Key Points:**
- Generator creates output, critic validates
- Loop continues until validation passes
- Use clear exit conditions
- Set max_iterations to prevent infinite loops

## 6. Iterative Refinement Pattern

**Use Case:** Qualitative improvement through multiple iterations.

**When to Use:**
- Content optimization
- Code quality improvements
- Design iterations

**Implementation:**

```python
generator = LlmAgent(
    name="Generator",
    instruction="Generate an initial draft.",
    output_key="current_draft"
)

critic = LlmAgent(
    name="Critic",
    instruction="Review {current_draft}. List specific improvement opportunities.",
    output_key="critique_notes"
)

refiner = LlmAgent(
    name="Refiner",
    instruction="Rewrite {current_draft} based on {critique_notes} for better quality.",
    output_key="current_draft"  # Overwrites for next iteration
)

refinement_loop = LoopAgent(
    name="RefinementLoop",
    max_iterations=3,
    sub_agents=[critic, refiner]
)

workflow = SequentialAgent(
    sub_agents=[generator, refinement_loop]
)
```

**Key Points:**
- Multiple passes for quality improvement
- Refiner overwrites draft each iteration
- Fixed iteration count (not condition-based)
- Balance quality vs. cost/time

## 7. Human-in-the-Loop Pattern

**Use Case:** Critical decisions requiring human authorization.

**When to Use:**
- Financial transactions
- Irreversible actions (deletes, deployments)
- High-stakes decisions

**Implementation:**

```python
from adk.tools import ApprovalTool

transaction_agent = LlmAgent(
    name="TransactionAgent",
    instruction="Handle routine processing. For high-stakes actions, use ApprovalTool to get human authorization.",
    tools=[ApprovalTool, PaymentProcessor]
)

approval_agent = LlmAgent(
    name="ApprovalToolAgent",
    instruction="Pause execution and request explicit human input before proceeding."
)

workflow = SequentialAgent(
    sub_agents=[transaction_agent, approval_agent]
)
```

**Key Points:**
- Pause execution for human decision
- Use for irreversible or high-consequence actions
- Clear communication of what's being approved
- Balance automation with control

## Combining Patterns

Production systems often combine multiple patterns:

```python
# Example: Customer Support System
# 1. Coordinator pattern for routing
# 2. Parallel pattern for documentation search
# 3. Generator-Critic pattern for response validation

coordinator = LlmAgent(
    name="SupportCoordinator",
    instruction="Route customer queries to appropriate specialist.",
    sub_agents=[billing_agent, tech_agent]
)

# Within tech_agent, use parallel search
parallel_search = ParallelAgent(
    sub_agents=[docs_searcher, forum_searcher, kb_searcher]
)

# Then validate response
response_loop = LoopAgent(
    sub_agents=[response_generator, quality_critic],
    exit_condition="PASS"
)
```

## Pattern Selection Guide

| Pattern | Complexity | Determinism | Use When |
|---------|------------|-------------|----------|
| Sequential | Low | High | Linear workflows |
| Coordinator | Medium | Medium | Intent routing |
| Parallel | Medium | Medium | Independent tasks |
| Hierarchical | High | Medium | Complex decomposition |
| Generator-Critic | Medium | Low | Quality validation |
| Iterative Refinement | Medium | Low | Quality optimization |
| Human-in-Loop | Low | High | Critical decisions |

## References

- [Developer's Guide to Multi-Agent Patterns](https://developers.googleblog.com/developers-guide-to-multi-agent-patterns-in-adk/)
- [ADK Multi-Agent Documentation](https://google.github.io/adk-docs/agents/multi-agents/)
