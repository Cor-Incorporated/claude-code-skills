# Contract-First API Design

## Table of Contents
1. [Workflow](#workflow)
2. [OpenAPI Schema First](#openapi-schema-first)
3. [Type Generation](#type-generation)
4. [tRPC Pattern](#trpc-pattern)
5. [GraphQL Pattern](#graphql-pattern)
6. [Versioning Strategy](#versioning-strategy)
7. [Error Contract](#error-contract)

---

## Workflow

```
1. Define API contract (OpenAPI / GraphQL schema / tRPC router)
    ↓
2. Generate types (server + client)
    ↓
3. Implement server (types guide implementation)
    ↓
4. Implement client (types ensure correctness)
    ↓
5. Contract changes → regenerate → compiler catches breaking changes
```

**Rule**: Schema is the single source of truth. Never hand-write types that the schema defines.

---

## OpenAPI Schema First

### Define the schema

```yaml
# openapi.yaml
openapi: '3.1.0'
info:
  title: Order API
  version: '1.0.0'
paths:
  /api/orders:
    post:
      operationId: placeOrder
      summary: Place a new order
      requestBody:
        required: true
        content:
          application/json:
            schema:
              $ref: '#/components/schemas/PlaceOrderRequest'
      responses:
        '201':
          description: Order placed
          content:
            application/json:
              schema:
                $ref: '#/components/schemas/OrderResponse'
        '400':
          $ref: '#/components/responses/ValidationError'
        '500':
          $ref: '#/components/responses/InternalError'

    get:
      operationId: listOrders
      summary: List orders
      parameters:
        - name: status
          in: query
          schema:
            $ref: '#/components/schemas/OrderStatus'
        - name: limit
          in: query
          schema:
            type: integer
            default: 20
            maximum: 100
        - name: cursor
          in: query
          schema:
            type: string
      responses:
        '200':
          description: Order list
          content:
            application/json:
              schema:
                $ref: '#/components/schemas/OrderListResponse'

components:
  schemas:
    PlaceOrderRequest:
      type: object
      required: [customerId, items]
      properties:
        customerId:
          type: string
          format: uuid
        items:
          type: array
          minItems: 1
          items:
            $ref: '#/components/schemas/OrderItemRequest'

    OrderItemRequest:
      type: object
      required: [productId, quantity]
      properties:
        productId:
          type: string
        quantity:
          type: integer
          minimum: 1

    OrderResponse:
      type: object
      required: [id, status, totalAmount, createdAt]
      properties:
        id:
          type: string
          format: uuid
        status:
          $ref: '#/components/schemas/OrderStatus'
        totalAmount:
          type: number
        currency:
          type: string
          default: JPY
        createdAt:
          type: string
          format: date-time

    OrderStatus:
      type: string
      enum: [draft, placed, paid, shipped, delivered, cancelled]

    OrderListResponse:
      type: object
      properties:
        items:
          type: array
          items:
            $ref: '#/components/schemas/OrderResponse'
        nextCursor:
          type: string
          nullable: true
        total:
          type: integer

  responses:
    ValidationError:
      description: Validation error
      content:
        application/json:
          schema:
            type: object
            properties:
              error:
                type: string
              details:
                type: array
                items:
                  type: object
                  properties:
                    field:
                      type: string
                    message:
                      type: string

    InternalError:
      description: Internal server error
      content:
        application/json:
          schema:
            type: object
            properties:
              error:
                type: string
              requestId:
                type: string
```

---

## Type Generation

### TypeScript (openapi-typescript)

```bash
# Generate types from OpenAPI spec
npx openapi-typescript openapi.yaml -o src/generated/api-types.ts
```

```typescript
// Generated types used in both server and client
import type { paths, components } from './generated/api-types'

type PlaceOrderRequest = components['schemas']['PlaceOrderRequest']
type OrderResponse = components['schemas']['OrderResponse']

// Server: type-safe route handler
app.post('/api/orders', async (req: Request<{}, {}, PlaceOrderRequest>, res: Response<OrderResponse>) => {
  // req.body is typed as PlaceOrderRequest
  // res.json() expects OrderResponse
})

// Client: type-safe fetch
const response = await fetch('/api/orders', {
  method: 'POST',
  body: JSON.stringify(request satisfies PlaceOrderRequest)
})
const order: OrderResponse = await response.json()
```

### Python (datamodel-code-generator)

```bash
# Generate Pydantic models from OpenAPI
datamodel-codegen --input openapi.yaml --output src/generated/models.py --output-model-type pydantic_v2.BaseModel
```

```python
# Generated models used in FastAPI
from generated.models import PlaceOrderRequest, OrderResponse

@router.post("/api/orders", response_model=OrderResponse, status_code=201)
async def place_order(request: PlaceOrderRequest) -> OrderResponse:
    # request is validated by Pydantic
    pass
```

---

## tRPC Pattern

For Next.js full-stack TypeScript projects. Zero-codegen type safety.

```typescript
// server/trpc/routers/order.ts
export const orderRouter = router({
  place: protectedProcedure
    .input(z.object({
      customerId: z.string().uuid(),
      items: z.array(z.object({
        productId: z.string(),
        quantity: z.number().int().positive()
      })).min(1)
    }))
    .mutation(async ({ input, ctx }) => {
      const useCase = ctx.container.resolve(PlaceOrderUseCase)
      return useCase.execute(input)
    }),

  list: protectedProcedure
    .input(z.object({
      status: z.enum(['draft', 'placed', 'shipped']).optional(),
      limit: z.number().int().min(1).max(100).default(20),
      cursor: z.string().optional()
    }))
    .query(async ({ input, ctx }) => {
      return ctx.orderReadModel.list(input)
    }),

  byId: protectedProcedure
    .input(z.object({ id: z.string().uuid() }))
    .query(async ({ input, ctx }) => {
      return ctx.orderReadModel.findById(input.id)
    })
})

// Client — fully typed, zero codegen
const { data } = trpc.order.list.useQuery({ status: 'placed' })
//       ^? OrderResponse[]

const mutation = trpc.order.place.useMutation()
await mutation.mutateAsync({
  customerId: '...',
  items: [{ productId: '...', quantity: 2 }]
})
```

---

## GraphQL Pattern

```graphql
# schema.graphql
type Order {
  id: ID!
  status: OrderStatus!
  totalAmount: Float!
  currency: String!
  items: [OrderItem!]!
  createdAt: DateTime!
}

enum OrderStatus {
  DRAFT
  PLACED
  PAID
  SHIPPED
  DELIVERED
  CANCELLED
}

input PlaceOrderInput {
  customerId: ID!
  items: [OrderItemInput!]!
}

input OrderItemInput {
  productId: ID!
  quantity: Int!
}

type Mutation {
  placeOrder(input: PlaceOrderInput!): Order!
}

type Query {
  order(id: ID!): Order
  orders(status: OrderStatus, first: Int = 20, after: String): OrderConnection!
}
```

```bash
# Generate TypeScript types
npx graphql-codegen
```

---

## Versioning Strategy

### URL versioning (recommended for REST)

```
/api/v1/orders
/api/v2/orders  # New version with breaking changes
```

### Header versioning (alternative)

```
Accept: application/vnd.myapp.v1+json
```

### Rules
1. Additive changes (new optional fields) = no version bump
2. Breaking changes (removed fields, type changes) = new version
3. Support at most 2 versions simultaneously
4. Deprecation notice 3 months before removal

---

## Error Contract

Standardize error responses across all APIs.

```typescript
// Shared error format
interface ApiError {
  error: {
    code: string           // Machine-readable: 'ORDER_NOT_FOUND'
    message: string        // Human-readable: 'Order with id xxx was not found'
    details?: ErrorDetail[]
    requestId: string      // For log correlation
  }
}

interface ErrorDetail {
  field: string
  code: string
  message: string
}

// Error codes per domain
const OrderErrorCodes = {
  NOT_FOUND: 'ORDER_NOT_FOUND',
  ALREADY_PLACED: 'ORDER_ALREADY_PLACED',
  EMPTY_CART: 'ORDER_EMPTY_CART',
  PAYMENT_FAILED: 'ORDER_PAYMENT_FAILED',
} as const
```

```python
# Python equivalent
from pydantic import BaseModel

class ErrorDetail(BaseModel):
    field: str
    code: str
    message: str

class ApiError(BaseModel):
    code: str
    message: str
    details: list[ErrorDetail] | None = None
    request_id: str
```
