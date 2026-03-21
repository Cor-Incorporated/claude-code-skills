# Clean Architecture / Hexagonal Architecture

## Table of Contents
1. [Layer Structure](#layer-structure)
2. [Dependency Rule](#dependency-rule)
3. [Ports and Adapters](#ports-and-adapters)
4. [Use Case Pattern](#use-case-pattern)
5. [Directory Templates](#directory-templates)
6. [DI Container Setup](#di-container-setup)
7. [Testing Strategy per Layer](#testing-strategy-per-layer)

---

## Layer Structure

```
┌─────────────────────────────────────────────────┐
│                 Infrastructure                   │
│  (DB, HTTP, MQ, External APIs, File System)      │
│                                                  │
│  ┌─────────────────────────────────────────────┐ │
│  │              Application                     │ │
│  │  (Use Cases, Application Services, DTOs)     │ │
│  │                                              │ │
│  │  ┌─────────────────────────────────────────┐ │ │
│  │  │              Domain                      │ │ │
│  │  │  (Entities, VOs, Events, Repo Ports)     │ │ │
│  │  │  ★ NO external dependencies              │ │ │
│  │  └─────────────────────────────────────────┘ │ │
│  └─────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────┘
```

---

## Dependency Rule

**Inner layers NEVER depend on outer layers. Dependencies point inward only.**

```typescript
// ✅ Domain defines the interface (Port)
// domain/repositories/order-repository.ts
interface OrderRepository {
  save(order: Order): Promise<void>
}

// ✅ Infrastructure implements it (Adapter)
// infrastructure/persistence/postgres-order-repository.ts
class PostgresOrderRepository implements OrderRepository {
  async save(order: Order): Promise<void> { /* ... */ }
}

// ❌ VIOLATION: Domain imports infrastructure
import { PrismaClient } from '@prisma/client'  // Never in domain layer
```

### Import rule enforcement

```
domain/     → imports nothing external
application/ → imports domain/ only
infrastructure/ → imports domain/ + application/ + external libs
```

---

## Ports and Adapters

### Port = Interface (domain/application boundary)

```typescript
// Primary Port (driving) — how the outside world drives the application
interface PlaceOrderUseCase {
  execute(command: PlaceOrderCommand): Promise<OrderId>
}

// Secondary Port (driven) — what the application needs from the outside
interface OrderRepository {
  findById(id: OrderId): Promise<Order | null>
  save(order: Order): Promise<void>
}

interface PaymentGateway {
  processPayment(payment: Payment): Promise<PaymentResult>
}

interface NotificationSender {
  sendOrderConfirmation(orderId: OrderId, email: Email): Promise<void>
}
```

### Adapter = Implementation (infrastructure layer)

```typescript
// Primary Adapter (driving) — HTTP Controller
class OrderController {
  constructor(private readonly placeOrder: PlaceOrderUseCase) {}

  async handlePost(req: Request, res: Response): Promise<void> {
    const command = PlaceOrderCommand.fromRequest(req.body)
    const orderId = await this.placeOrder.execute(command)
    res.status(201).json({ orderId: orderId.value })
  }
}

// Secondary Adapter (driven) — Database
class PostgresOrderRepository implements OrderRepository { /* ... */ }

// Secondary Adapter (driven) — External API
class StripePaymentGateway implements PaymentGateway { /* ... */ }

// Secondary Adapter (driven) — Email
class SendGridNotificationSender implements NotificationSender { /* ... */ }
```

### Adapter swapping (the core benefit)

```typescript
// Development: In-memory
container.bind(OrderRepository).to(InMemoryOrderRepository)

// Production: PostgreSQL
container.bind(OrderRepository).to(PostgresOrderRepository)

// Testing: Mock
container.bind(OrderRepository).to(MockOrderRepository)

// Migration: Switch AI provider
container.bind(AIProvider).to(AnthropicAdapter)    // was: OpenAIAdapter
```

---

## Use Case Pattern

One class per use case. Single Responsibility.

```typescript
// application/use-cases/place-order.ts
class PlaceOrderUseCase {
  constructor(
    private readonly orderRepo: OrderRepository,
    private readonly paymentGateway: PaymentGateway,
    private readonly eventPublisher: EventPublisher
  ) {}

  async execute(command: PlaceOrderCommand): Promise<OrderId> {
    // 1. Validate & create domain object
    const order = OrderFactory.createFromCommand(command)

    // 2. Domain logic
    const placedOrder = order.place()

    // 3. Persist
    await this.orderRepo.save(placedOrder)

    // 4. Publish domain events
    const events = placedOrder.pullDomainEvents()
    await this.eventPublisher.publishAll(events)

    return placedOrder.id
  }
}

// Command (input DTO)
class PlaceOrderCommand {
  constructor(
    readonly customerId: string,
    readonly items: Array<{ productId: string; quantity: number }>,
    readonly shippingAddress: AddressDTO
  ) {}

  static fromRequest(body: unknown): PlaceOrderCommand {
    const parsed = PlaceOrderSchema.parse(body)  // Zod validation
    return new PlaceOrderCommand(parsed.customerId, parsed.items, parsed.shippingAddress)
  }
}
```

### Python use case

```python
@dataclass
class PlaceOrderCommand:
    customer_id: str
    items: list[OrderItemDTO]
    shipping_address: AddressDTO

class PlaceOrderUseCase:
    def __init__(
        self,
        order_repo: OrderRepository,
        payment_gateway: PaymentGateway,
        event_publisher: EventPublisher,
    ) -> None:
        self._order_repo = order_repo
        self._payment_gateway = payment_gateway
        self._event_publisher = event_publisher

    async def execute(self, command: PlaceOrderCommand) -> OrderId:
        order = OrderFactory.create_from_command(command)
        placed_order = order.place()
        await self._order_repo.save(placed_order)
        await self._event_publisher.publish_all(placed_order.pull_domain_events())
        return placed_order.id
```

---

## Directory Templates

### TypeScript (Next.js / Node.js)

```
src/
├── modules/
│   └── orders/                        # Feature module = Bounded Context
│       ├── domain/
│       │   ├── model/
│       │   │   ├── order.ts           # Aggregate Root
│       │   │   ├── order-item.ts      # Entity
│       │   │   ├── order-id.ts        # Value Object (branded type)
│       │   │   └── order-status.ts    # Value Object (enum)
│       │   ├── events/
│       │   │   ├── order-placed.ts
│       │   │   └── order-cancelled.ts
│       │   ├── ports/
│       │   │   ├── order-repository.ts
│       │   │   └── payment-gateway.ts
│       │   └── services/
│       │       └── pricing-service.ts
│       ├── application/
│       │   ├── use-cases/
│       │   │   ├── place-order.ts
│       │   │   ├── cancel-order.ts
│       │   │   └── get-order.ts
│       │   └── dto/
│       │       ├── place-order-command.ts
│       │       └── order-response.ts
│       └── infrastructure/
│           ├── persistence/
│           │   ├── postgres-order-repository.ts
│           │   └── order-mapper.ts
│           ├── api/
│           │   └── order-controller.ts
│           └── messaging/
│               └── order-event-publisher.ts
├── shared/
│   └── kernel/
│       ├── money.ts
│       ├── domain-event.ts
│       └── event-bus.ts
└── main.ts                            # Composition Root (DI)
```

### Python (FastAPI)

```
src/
├── modules/
│   └── orders/
│       ├── domain/
│       │   ├── model/
│       │   │   ├── order.py
│       │   │   └── value_objects.py
│       │   ├── events/
│       │   ├── ports/
│       │   │   └── order_repository.py  # Protocol class
│       │   └── services/
│       ├── application/
│       │   ├── use_cases/
│       │   │   └── place_order.py
│       │   └── dto/
│       ├── infrastructure/
│       │   ├── persistence/
│       │   │   └── sqlalchemy_order_repository.py
│       │   ├── api/
│       │   │   └── order_router.py
│       │   └── messaging/
│       └── __init__.py
├── shared/
│   └── kernel/
└── main.py
```

### Go

```
internal/
├── orders/
│   ├── domain/
│   │   ├── order.go           # Aggregate + Entity
│   │   ├── value_objects.go   # VOs
│   │   ├── events.go          # Domain Events
│   │   ├── repository.go      # Interface
│   │   └── service.go         # Domain Service
│   ├── application/
│   │   ├── place_order.go     # Use Case
│   │   └── dto.go
│   └── infrastructure/
│       ├── postgres_repo.go
│       ├── handler.go         # HTTP handler
│       └── publisher.go
└── shared/
    └── kernel/
```

---

## DI Container Setup

### TypeScript (tsyringe)

```typescript
import { container } from 'tsyringe'

// Register adapters
container.register<OrderRepository>('OrderRepository', {
  useClass: PostgresOrderRepository
})
container.register<PaymentGateway>('PaymentGateway', {
  useClass: StripePaymentGateway
})

// Resolve use case (auto-injects dependencies)
const placeOrder = container.resolve(PlaceOrderUseCase)
```

### Python (dependency-injector)

```python
from dependency_injector import containers, providers

class OrderContainer(containers.DeclarativeContainer):
    db = providers.Singleton(AsyncSession)
    order_repo = providers.Factory(SqlAlchemyOrderRepository, session=db)
    payment_gateway = providers.Factory(StripePaymentGateway)
    place_order = providers.Factory(
        PlaceOrderUseCase,
        order_repo=order_repo,
        payment_gateway=payment_gateway,
    )
```

---

## Testing Strategy per Layer

| Layer | Test Type | Dependencies | Speed |
|-------|-----------|-------------|-------|
| Domain | Unit test | None (pure logic) | < 1ms |
| Application | Unit test | Mocked ports | < 10ms |
| Infrastructure | Integration test | Real DB / API | < 1s |
| E2E | E2E test | Full stack | < 5s |

```typescript
// Domain test — zero dependencies
describe('Order', () => {
  it('calculates total from items', () => {
    const order = Order.create(OrderId.generate())
      .addItem(OrderItem.create('p1', 2, Money.of(1000, 'JPY')))
      .addItem(OrderItem.create('p2', 1, Money.of(500, 'JPY')))

    expect(order.totalAmount).toEqual(Money.of(2500, 'JPY'))
  })
})

// Application test — mocked ports
describe('PlaceOrderUseCase', () => {
  it('saves order and publishes event', async () => {
    const mockRepo = { save: vi.fn() }
    const mockPublisher = { publishAll: vi.fn() }
    const useCase = new PlaceOrderUseCase(mockRepo, mockGateway, mockPublisher)

    await useCase.execute(command)

    expect(mockRepo.save).toHaveBeenCalledOnce()
    expect(mockPublisher.publishAll).toHaveBeenCalledWith(
      expect.arrayContaining([expect.any(OrderPlaced)])
    )
  })
})
```
