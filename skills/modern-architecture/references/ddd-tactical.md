# DDD Tactical Patterns

## Table of Contents
1. [Value Object](#value-object)
2. [Entity](#entity)
3. [Aggregate](#aggregate)
4. [Repository](#repository)
5. [Domain Event](#domain-event)
6. [Domain Service](#domain-service)
7. [Factory](#factory)
8. [Language-Specific Examples](#language-specific-examples)

---

## Value Object

Immutable, equality by value. No identity.

```typescript
// TypeScript
class Money {
  private constructor(
    readonly amount: number,
    readonly currency: string
  ) {
    if (amount < 0) throw new Error('Amount must be non-negative')
    if (!['JPY', 'USD', 'EUR'].includes(currency)) throw new Error('Unsupported currency')
  }

  static of(amount: number, currency: string): Money {
    return new Money(amount, currency)
  }

  add(other: Money): Money {
    if (this.currency !== other.currency) throw new Error('Currency mismatch')
    return Money.of(this.amount + other.amount, this.currency)
  }

  equals(other: Money): boolean {
    return this.amount === other.amount && this.currency === other.currency
  }
}
```

```python
# Python
from dataclasses import dataclass

@dataclass(frozen=True)
class Money:
    amount: int
    currency: str

    def __post_init__(self):
        if self.amount < 0:
            raise ValueError("Amount must be non-negative")

    def add(self, other: "Money") -> "Money":
        if self.currency != other.currency:
            raise ValueError("Currency mismatch")
        return Money(amount=self.amount + other.amount, currency=self.currency)
```

```go
// Go
type Money struct {
    amount   int
    currency string
}

func NewMoney(amount int, currency string) (Money, error) {
    if amount < 0 {
        return Money{}, errors.New("amount must be non-negative")
    }
    return Money{amount: amount, currency: currency}, nil
}

func (m Money) Add(other Money) (Money, error) {
    if m.currency != other.currency {
        return Money{}, errors.New("currency mismatch")
    }
    return NewMoney(m.amount+other.amount, m.currency)
}
```

### When to use Value Object
- Quantities, measurements, ranges
- Identifiers (Email, PhoneNumber, OrderId)
- Composite values (Address, DateRange, Coordinate)

---

## Entity

Has identity. Mutable through controlled methods.

```typescript
class Order {
  private constructor(
    readonly id: OrderId,
    private _items: ReadonlyArray<OrderItem>,
    private _status: OrderStatus
  ) {}

  static create(id: OrderId): Order {
    return new Order(id, [], OrderStatus.Draft)
  }

  addItem(item: OrderItem): Order {
    if (this._status !== OrderStatus.Draft) {
      throw new Error('Cannot add items to non-draft order')
    }
    return new Order(this.id, [...this._items, item], this._status)
  }

  get totalAmount(): Money {
    return this._items.reduce(
      (sum, item) => sum.add(item.subtotal),
      Money.of(0, 'JPY')
    )
  }
}
```

### Identity rule
- Two entities are equal if and only if their IDs match
- Use branded types or wrapper classes for IDs: `type OrderId = string & { readonly __brand: 'OrderId' }`

---

## Aggregate

Consistency boundary. One Aggregate Root per transaction.

```
Order (Aggregate Root)
├── OrderItem (Entity, internal)
├── ShippingAddress (Value Object)
└── OrderStatus (Value Object)
```

### Rules
1. Reference other Aggregates by ID only, never by direct object reference
2. One transaction = one Aggregate mutation
3. Eventual consistency between Aggregates (via Domain Events)
4. Keep Aggregates small — prefer more Aggregates over fewer large ones

```typescript
// ❌ Direct reference (violation)
class Order {
  customer: Customer  // Cross-aggregate reference
}

// ✅ Reference by ID
class Order {
  customerId: CustomerId  // ID reference only
}
```

---

## Repository

Collection-like interface for Aggregate persistence. One Repository per Aggregate Root.

```typescript
// Port (domain layer)
interface OrderRepository {
  findById(id: OrderId): Promise<Order | null>
  findByCustomer(customerId: CustomerId): Promise<Order[]>
  save(order: Order): Promise<void>
  delete(id: OrderId): Promise<void>
}

// Adapter (infrastructure layer)
class PostgresOrderRepository implements OrderRepository {
  constructor(private readonly db: Pool) {}

  async findById(id: OrderId): Promise<Order | null> {
    const row = await this.db.query('SELECT * FROM orders WHERE id = $1', [id])
    return row ? OrderMapper.toDomain(row) : null
  }

  async save(order: Order): Promise<void> {
    await this.db.query(
      'INSERT INTO orders (id, status, total) VALUES ($1, $2, $3) ON CONFLICT (id) DO UPDATE SET status = $2, total = $3',
      [order.id, order.status, order.totalAmount.amount]
    )
  }
}
```

### Rules
- Repository interface lives in domain layer
- Repository implementation lives in infrastructure layer
- No query logic in domain — queries go through Read Model (CQRS) or Repository methods

---

## Domain Event

Record of something that happened in the domain. Past tense naming.

```typescript
interface DomainEvent {
  readonly eventId: string
  readonly occurredAt: Date
  readonly aggregateId: string
}

class OrderPlaced implements DomainEvent {
  readonly eventId = crypto.randomUUID()
  readonly occurredAt = new Date()

  constructor(
    readonly aggregateId: string,
    readonly customerId: string,
    readonly totalAmount: Money,
    readonly items: ReadonlyArray<{ productId: string; quantity: number }>
  ) {}
}

// Aggregate emits events
class Order {
  private _domainEvents: DomainEvent[] = []

  place(): Order {
    if (this._status !== OrderStatus.Draft) throw new Error('Already placed')
    const updated = new Order(this.id, this._items, OrderStatus.Placed)
    updated._domainEvents.push(
      new OrderPlaced(this.id.value, this.customerId.value, this.totalAmount, this.itemSummary)
    )
    return updated
  }

  pullDomainEvents(): { events: DomainEvent[]; cleared: this } {
    const events = [...this._domainEvents]
    // Immutable: return new state instead of mutating
    const cleared = Object.create(
      Object.getPrototypeOf(this),
      Object.getOwnPropertyDescriptors({ ...this, _domainEvents: [] })
    )
    return { events, cleared }
  }
}
```

### Naming convention
- `OrderPlaced`, `PaymentReceived`, `ShipmentDispatched` (past tense)
- Include only data needed by consumers

---

## Domain Service

Stateless operations that don't belong to a single Entity/VO.

```typescript
class PricingService {
  calculateDiscount(
    order: Order,
    customerTier: CustomerTier,
    promotions: Promotion[]
  ): Money {
    const baseDiscount = customerTier === CustomerTier.Premium
      ? order.totalAmount.multiply(0.1)
      : Money.of(0, 'JPY')

    const promoDiscount = promotions
      .filter(p => p.isApplicable(order))
      .reduce((sum, p) => sum.add(p.calculateAmount(order)), Money.of(0, 'JPY'))

    return baseDiscount.add(promoDiscount)
  }
}
```

### When to use
- Operation spans multiple Aggregates
- Complex calculation involving multiple domain concepts
- Not a natural behavior of any single Entity

---

## Factory

Encapsulate complex creation logic.

```typescript
class OrderFactory {
  static createFromCart(
    cart: Cart,
    shippingAddress: Address,
    paymentMethod: PaymentMethod
  ): Order {
    if (cart.isEmpty) throw new Error('Cannot create order from empty cart')

    const items = cart.items.map(ci =>
      OrderItem.create(ci.productId, ci.quantity, ci.unitPrice)
    )

    return Order.create(
      OrderId.generate(),
      items,
      shippingAddress,
      paymentMethod
    )
  }
}
```

---

## Language-Specific Examples

### Python with Pydantic

```python
from pydantic import BaseModel, field_validator
from uuid import UUID, uuid4

class OrderId(BaseModel):
    value: UUID

    @classmethod
    def generate(cls) -> "OrderId":
        return cls(value=uuid4())

class OrderItem(BaseModel):
    product_id: str
    quantity: int
    unit_price: Money

    @field_validator("quantity")
    @classmethod
    def validate_quantity(cls, v: int) -> int:
        if v <= 0:
            raise ValueError("Quantity must be positive")
        return v

    @property
    def subtotal(self) -> Money:
        return Money(amount=self.unit_price.amount * self.quantity, currency=self.unit_price.currency)
```

### Go with Functional Options

```go
type Order struct {
    id       OrderID
    items    []OrderItem
    status   OrderStatus
    events   []DomainEvent
}

type OrderOption func(*Order) error

func WithItems(items []OrderItem) OrderOption {
    return func(o *Order) error {
        if len(items) == 0 {
            return errors.New("at least one item required")
        }
        o.items = items
        return nil
    }
}

func NewOrder(id OrderID, opts ...OrderOption) (*Order, error) {
    o := &Order{id: id, status: Draft}
    for _, opt := range opts {
        if err := opt(o); err != nil {
            return nil, err
        }
    }
    return o, nil
}
```
