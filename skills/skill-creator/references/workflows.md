# Workflow Patterns

## Pattern 1: Sequential Workflow

Use when: Multi-step processes in a specific order.

```markdown
## Workflow: Onboard New Customer

### Step 1: Create Account
Call MCP tool: `create_customer`
Parameters: name, email, company

### Step 2: Setup Payment
Call MCP tool: `setup_payment_method`
Wait for: payment method verification

### Step 3: Create Subscription
Call MCP tool: `create_subscription`
Parameters: plan_id, customer_id (from Step 1)
```

Key techniques: explicit step ordering, dependencies between steps, validation at each stage, rollback instructions for failures.

## Pattern 2: Conditional Workflow

Use when: Tasks with branching logic.

```markdown
1. Determine the modification type:
   **Creating new content?** -> Follow "Creation workflow" below
   **Editing existing content?** -> Follow "Editing workflow" below

2. Creation workflow: [steps]
3. Editing workflow: [steps]
```

## Pattern 3: Multi-MCP Coordination

Use when: Workflows span multiple services.

```markdown
### Phase 1: Design Export (Figma MCP)
1. Export design assets
2. Generate design specifications

### Phase 2: Asset Storage (Drive MCP)
1. Create project folder
2. Upload all assets

### Phase 3: Task Creation (Linear MCP)
1. Create development tasks
2. Attach asset links to tasks
```

Key techniques: clear phase separation, data passing between MCPs, validation before moving to next phase.

## Pattern 4: Iterative Refinement

Use when: Output quality improves with iteration.

```markdown
### Initial Draft
1. Fetch data via MCP
2. Generate first draft

### Quality Check
1. Run validation script: `scripts/check_report.py`
2. Identify issues

### Refinement Loop
1. Address each identified issue
2. Regenerate affected sections
3. Re-validate
4. Repeat until quality threshold met

### Finalization
1. Apply final formatting
2. Generate summary
```

## Pattern 5: Context-Aware Tool Selection

Use when: Same outcome, different tools depending on context.

```markdown
### Decision Tree
1. Check file type and size
2. Determine best storage location:
   - Large files (>10MB): Use cloud storage MCP
   - Code files: Use GitHub MCP
   - Temporary files: Use local storage

### Execute Storage
Based on decision:
- Call appropriate MCP tool
- Apply service-specific metadata
```
