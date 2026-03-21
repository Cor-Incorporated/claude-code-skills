# Event-Driven Architecture

## Table of Contents
1. [Event Types](#event-types)
2. [Event Bus Pattern](#event-bus-pattern)
3. [CQRS](#cqrs)
4. [Event Sourcing](#event-sourcing)
5. [Pub/Sub Patterns](#pubsub-patterns)
6. [Real-Time Integration](#real-time-integration)

---

## Event Types

| Type | Purpose | Example | Persistence |
|------|---------|---------|-------------|
| Domain Event | 集約内の変化を記録 | `OrderPlaced` | Optional |
| Integration Event | コンテキスト間の通知 | `OrderPlacedIntegrationEvent` | Required |
| Command | アクション要求 | `PlaceOrderCommand` | No |

```typescript
// Domain Event — internal to Bounded Context
class OrderPlaced implements DomainEvent {
  constructor(
    readonly orderId: string,
    readonly items: OrderItem[],
    readonly totalAmount: Money
  ) {}
}

// Integration Event — crosses Bounded Context boundaries
class OrderPlacedIntegrationEvent {
  constructor(
    readonly eventId: string,
    readonly orderId: string,
    readonly totalAmount: number,
    readonly currency: string,
    readonly occurredAt: string  // ISO 8601
  ) {}

  static fromDomain(event: OrderPlaced): OrderPlacedIntegrationEvent {
    return new OrderPlacedIntegrationEvent(
      crypto.randomUUID(),
      event.orderId,
      event.totalAmount.amount,
      event.totalAmount.currency,
      new Date().toISOString()
    )
  }
}
```

---

## Event Bus Pattern

### In-Process Event Bus

```typescript
type EventHandler<T extends DomainEvent> = (event: T) => Promise<void>

class InProcessEventBus implements EventBus {
  private handlers = new Map<string, EventHandler<any>[]>()

  subscribe<T extends DomainEvent>(
    eventType: string,
    handler: EventHandler<T>
  ): void {
    const existing = this.handlers.get(eventType) ?? []
    this.handlers.set(eventType, [...existing, handler])
  }

  async publish(event: DomainEvent): Promise<void> {
    const handlers = this.handlers.get(event.constructor.name) ?? []
    await Promise.all(handlers.map(h => h(event)))
  }

  async publishAll(events: DomainEvent[]): Promise<void> {
    for (const event of events) {
      await this.publish(event)
    }
  }
}
```

### Python Event Bus

```python
from collections import defaultdict
from typing import Any, Callable, Coroutine

EventHandler = Callable[[Any], Coroutine[Any, Any, None]]

class EventBus:
    def __init__(self) -> None:
        self._handlers: dict[str, list[EventHandler]] = defaultdict(list)

    def subscribe(self, event_type: str, handler: EventHandler) -> None:
        self._handlers[event_type].append(handler)

    async def publish(self, event: object) -> None:
        event_type = type(event).__name__
        for handler in self._handlers.get(event_type, []):
            await handler(event)
```

---

## CQRS

Command Query Responsibility Segregation. Separate models for writes and reads.

```
┌──────────┐     Command      ┌──────────────┐     ┌──────────┐
│  Client   │────────────────▶│  Write Model  │────▶│ Event DB │
│           │                  │  (Aggregates)  │     └──────────┘
│           │     Query        ├──────────────┤          │
│           │◀────────────────│  Read Model   │◀─────────┘
└──────────┘                  │  (Projections) │    (Event Handler
                              └──────────────┘     updates read model)
```

### Write Side (Command)

```typescript
// Command handler — validates, mutates aggregate, persists
class PlaceOrderCommandHandler {
  constructor(
    private readonly orderRepo: OrderRepository,
    private readonly eventPublisher: EventPublisher
  ) {}

  async handle(command: PlaceOrderCommand): Promise<OrderId> {
    const order = Order.create(command.customerId, command.items)
    const placed = order.place()
    await this.orderRepo.save(placed)
    await this.eventPublisher.publishAll(placed.pullDomainEvents())
    return placed.id
  }
}
```

### Read Side (Query)

```typescript
// Query model — optimized for reads, denormalized
interface OrderView {
  orderId: string
  customerName: string
  status: string
  totalAmount: number
  itemCount: number
  placedAt: string
}

// Projection — updates read model when events occur
class OrderProjection {
  constructor(private readonly readDb: ReadDatabase) {}

  async onOrderPlaced(event: OrderPlaced): Promise<void> {
    await this.readDb.upsert('order_views', {
      orderId: event.orderId,
      status: 'placed',
      totalAmount: event.totalAmount.amount,
      itemCount: event.items.length,
      placedAt: event.occurredAt.toISOString()
    })
  }

  async onOrderShipped(event: OrderShipped): Promise<void> {
    await this.readDb.update('order_views', event.orderId, {
      status: 'shipped',
      shippedAt: event.occurredAt.toISOString()
    })
  }
}

// Query handler — simple read
class GetOrderQueryHandler {
  constructor(private readonly readDb: ReadDatabase) {}

  async handle(query: GetOrderQuery): Promise<OrderView | null> {
    return this.readDb.findById('order_views', query.orderId)
  }
}
```

### When to use CQRS
- Read/write patterns differ significantly
- Read model needs denormalization for performance
- Multiple read representations of same data
- Event-driven systems where projections are natural

### When NOT to use CQRS
- Simple CRUD with no complex reads
- Small-scale applications
- Team unfamiliar with eventual consistency

---

## Event Sourcing

Store state as a sequence of events, not as current state.

```typescript
class EventSourcedOrder {
  private state: OrderState = { status: 'new', items: [], version: 0 }
  private uncommittedEvents: DomainEvent[] = []

  // Rebuild from event history
  static fromHistory(events: DomainEvent[]): EventSourcedOrder {
    const order = new EventSourcedOrder()
    for (const event of events) {
      order.apply(event, false)
    }
    return order
  }

  place(customerId: string, items: OrderItem[]): void {
    this.apply(new OrderPlaced(this.id, customerId, items), true)
  }

  private apply(event: DomainEvent, isNew: boolean): void {
    // State transition — pure function
    this.state = this.evolve(this.state, event)
    if (isNew) {
      this.uncommittedEvents.push(event)
    }
  }

  private evolve(state: OrderState, event: DomainEvent): OrderState {
    switch (event.constructor.name) {
      case 'OrderPlaced':
        return { ...state, status: 'placed', items: (event as OrderPlaced).items, version: state.version + 1 }
      case 'OrderCancelled':
        return { ...state, status: 'cancelled', version: state.version + 1 }
      default:
        return state
    }
  }
}

// Event Store
interface EventStore {
  append(aggregateId: string, events: DomainEvent[], expectedVersion: number): Promise<void>
  getEvents(aggregateId: string): Promise<DomainEvent[]>
}
```

### When to use Event Sourcing
- Full audit trail required
- Need to replay/recompute state
- Complex business rules with temporal queries
- Debugging requires "what happened?" answers

---

## Pub/Sub Patterns

### With Cloud Pub/Sub (GCP)

```typescript
class CloudPubSubEventPublisher implements EventPublisher {
  constructor(private readonly pubsub: PubSub) {}

  async publish(event: IntegrationEvent): Promise<void> {
    const topic = this.pubsub.topic(event.constructor.name)
    await topic.publishMessage({
      json: event,
      attributes: {
        eventType: event.constructor.name,
        version: '1.0',
        timestamp: new Date().toISOString()
      }
    })
  }
}
```

### With Redis Streams

```typescript
class RedisEventPublisher implements EventPublisher {
  constructor(private readonly redis: Redis) {}

  async publish(event: IntegrationEvent): Promise<void> {
    await this.redis.xadd(
      `events:${event.constructor.name}`,
      '*',
      'data', JSON.stringify(event),
      'type', event.constructor.name
    )
  }
}
```

---

## Real-Time Integration

For WebSocket/SSE-based real-time applications (common in user's projects).

```typescript
// Domain Event → WebSocket broadcast
class RealtimeEventBridge {
  constructor(
    private readonly eventBus: EventBus,
    private readonly wsServer: WebSocketServer
  ) {
    eventBus.subscribe('OrderStatusChanged', this.onOrderStatusChanged.bind(this))
  }

  private async onOrderStatusChanged(event: OrderStatusChanged): Promise<void> {
    this.wsServer.broadcast(event.customerId, {
      type: 'order:status_changed',
      payload: {
        orderId: event.orderId,
        newStatus: event.newStatus,
        updatedAt: event.occurredAt.toISOString()
      }
    })
  }
}
```

### Pattern: Event → Projection → WebSocket

```
Domain Event
    ↓
Event Handler (update read model)
    ↓
Change Detection (compare before/after)
    ↓
WebSocket Push (notify connected clients)
```

This pattern applies to:
- Real-time dashboards
- Live chat / AI streaming responses
- IoT sensor data feeds
- Collaborative editing
