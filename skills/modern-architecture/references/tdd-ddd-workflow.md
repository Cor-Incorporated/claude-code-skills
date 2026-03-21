# TDD × DDD Integration Workflow

## Table of Contents
1. [Outside-In TDD](#outside-in-tdd)
2. [Phase-by-Phase Workflow](#phase-by-phase-workflow)
3. [Test Pyramid with DDD](#test-pyramid-with-ddd)
4. [Domain Model Testing](#domain-model-testing)
5. [Use Case Testing](#use-case-testing)
6. [Integration Testing](#integration-testing)
7. [Property-Based Testing](#property-based-testing)

---

## Outside-In TDD

Start from the outermost layer (acceptance test), work inward.

```
1. Write failing acceptance test (E2E / API test)
    ↓
2. Write failing use case test (application layer)
    ↓
3. Write failing domain model test (domain layer)
    ↓
4. Implement domain model (GREEN)
    ↓
5. Implement use case (GREEN)
    ↓
6. Implement infrastructure adapter (GREEN)
    ↓
7. Acceptance test passes (GREEN)
    ↓
8. Refactor
```

---

## Phase-by-Phase Workflow

### Phase 0: Define the Domain Language

Before writing any code, clarify domain terms with domain experts or project requirements.

```markdown
## Ubiquitous Language: Order Domain
- **Order**: 顧客からの商品購入の意思表示
- **Place**: 注文を確定する行為
- **OrderItem**: 注文内の個別商品と数量
- **Cancel**: 注文を取り消す行為（出荷前のみ可能）
```

### Phase 1: Acceptance Test (RED)

```typescript
// test/e2e/place-order.e2e.test.ts
describe('POST /api/orders', () => {
  it('places an order and returns 201 with order details', async () => {
    const response = await request(app)
      .post('/api/orders')
      .send({
        customerId: 'customer-123',
        items: [
          { productId: 'product-1', quantity: 2 },
          { productId: 'product-2', quantity: 1 }
        ]
      })

    expect(response.status).toBe(201)
    expect(response.body).toMatchObject({
      id: expect.any(String),
      status: 'placed',
      totalAmount: expect.any(Number),
      items: expect.arrayContaining([
        expect.objectContaining({ productId: 'product-1', quantity: 2 })
      ])
    })
  })
})
// → RED: nothing exists yet
```

### Phase 2: Domain Model Test (RED → GREEN)

```typescript
// test/unit/domain/order.test.ts
describe('Order', () => {
  describe('create', () => {
    it('creates a draft order with given items', () => {
      const order = Order.create(
        OrderId.of('order-1'),
        CustomerId.of('customer-1'),
        [
          OrderItem.create('product-1', 2, Money.of(1000, 'JPY')),
          OrderItem.create('product-2', 1, Money.of(500, 'JPY'))
        ]
      )

      expect(order.status).toBe(OrderStatus.Draft)
      expect(order.items).toHaveLength(2)
      expect(order.totalAmount).toEqual(Money.of(2500, 'JPY'))
    })
  })

  describe('place', () => {
    it('transitions to placed status', () => {
      const order = createDraftOrder()
      const placed = order.place()

      expect(placed.status).toBe(OrderStatus.Placed)
    })

    it('emits OrderPlaced domain event', () => {
      const order = createDraftOrder()
      const placed = order.place()
      const events = placed.pullDomainEvents()

      expect(events).toHaveLength(1)
      expect(events[0]).toBeInstanceOf(OrderPlaced)
    })

    it('rejects placing an already-placed order', () => {
      const order = createDraftOrder().place()

      expect(() => order.place()).toThrow('Order is already placed')
    })
  })

  describe('cancel', () => {
    it('cancels a placed order', () => {
      const order = createDraftOrder().place()
      const cancelled = order.cancel('Customer requested')

      expect(cancelled.status).toBe(OrderStatus.Cancelled)
    })

    it('rejects cancelling a shipped order', () => {
      const order = createShippedOrder()

      expect(() => order.cancel('Changed mind')).toThrow('Cannot cancel shipped order')
    })
  })
})

// Test helper — creates domain objects for testing
function createDraftOrder(): Order {
  return Order.create(
    OrderId.of('test-order'),
    CustomerId.of('test-customer'),
    [OrderItem.create('product-1', 1, Money.of(1000, 'JPY'))]
  )
}
```

Now implement `Order`, `OrderItem`, `Money`, `OrderId`, etc. to make tests GREEN.

### Phase 3: Use Case Test (RED → GREEN)

```typescript
// test/unit/application/place-order.test.ts
describe('PlaceOrderUseCase', () => {
  let useCase: PlaceOrderUseCase
  let mockOrderRepo: MockOrderRepository
  let mockProductRepo: MockProductRepository
  let mockEventPublisher: MockEventPublisher

  beforeEach(() => {
    mockOrderRepo = new MockOrderRepository()
    mockProductRepo = new MockProductRepository()
    mockEventPublisher = new MockEventPublisher()
    mockProductRepo.addProduct('product-1', Money.of(1000, 'JPY'))

    useCase = new PlaceOrderUseCase(mockOrderRepo, mockProductRepo, mockEventPublisher)
  })

  it('creates and saves a placed order', async () => {
    const command = new PlaceOrderCommand(
      'customer-1',
      [{ productId: 'product-1', quantity: 2 }]
    )

    const orderId = await useCase.execute(command)

    const savedOrder = await mockOrderRepo.findById(orderId)
    expect(savedOrder).not.toBeNull()
    expect(savedOrder!.status).toBe(OrderStatus.Placed)
  })

  it('publishes domain events', async () => {
    const command = new PlaceOrderCommand(
      'customer-1',
      [{ productId: 'product-1', quantity: 1 }]
    )

    await useCase.execute(command)

    expect(mockEventPublisher.publishedEvents).toHaveLength(1)
    expect(mockEventPublisher.publishedEvents[0]).toBeInstanceOf(OrderPlaced)
  })

  it('rejects order with unknown product', async () => {
    const command = new PlaceOrderCommand(
      'customer-1',
      [{ productId: 'unknown-product', quantity: 1 }]
    )

    await expect(useCase.execute(command)).rejects.toThrow('Product not found')
  })
})
```

Now implement `PlaceOrderUseCase` to make tests GREEN.

### Phase 4: Infrastructure Adapter (Integration Test)

```typescript
// test/integration/postgres-order-repository.test.ts
describe('PostgresOrderRepository', () => {
  let repo: PostgresOrderRepository
  let db: TestDatabase

  beforeAll(async () => {
    db = await TestDatabase.setup()
    repo = new PostgresOrderRepository(db.pool)
  })

  afterAll(async () => {
    await db.teardown()
  })

  it('saves and retrieves an order', async () => {
    const order = createDraftOrder().place()

    await repo.save(order)
    const retrieved = await repo.findById(order.id)

    expect(retrieved).not.toBeNull()
    expect(retrieved!.id).toEqual(order.id)
    expect(retrieved!.status).toBe(OrderStatus.Placed)
    expect(retrieved!.totalAmount).toEqual(order.totalAmount)
  })
})
```

### Phase 5: Acceptance Test Passes (GREEN)

Wire everything together in the composition root → E2E test should now pass.

---

## Test Pyramid with DDD

```
        ▲
       / \       E2E Tests (5-10%)
      /   \      - Full HTTP request → response
     /     \     - Real DB, real adapters
    /───────\
   /         \   Integration Tests (15-25%)
  /           \  - Repository + Real DB
 /             \ - External API with testcontainers
/───────────────\
                  Unit Tests (65-80%)
                  - Domain model (pure logic, no mocks)
                  - Use cases (mocked ports)
                  - Value objects, entities
```

### Test speed targets

| Layer | Target | Acceptable |
|-------|--------|-----------|
| Domain unit | < 1ms | < 5ms |
| Use case unit | < 10ms | < 50ms |
| Integration | < 500ms | < 2s |
| E2E | < 3s | < 10s |

---

## Domain Model Testing

### Value Object tests

```typescript
describe('Money', () => {
  it('adds same currency', () => {
    const result = Money.of(100, 'JPY').add(Money.of(200, 'JPY'))
    expect(result).toEqual(Money.of(300, 'JPY'))
  })

  it('rejects adding different currencies', () => {
    expect(() =>
      Money.of(100, 'JPY').add(Money.of(100, 'USD'))
    ).toThrow('Currency mismatch')
  })

  it('rejects negative amounts', () => {
    expect(() => Money.of(-1, 'JPY')).toThrow('non-negative')
  })

  it('equality by value', () => {
    expect(Money.of(100, 'JPY').equals(Money.of(100, 'JPY'))).toBe(true)
    expect(Money.of(100, 'JPY').equals(Money.of(200, 'JPY'))).toBe(false)
  })
})
```

### State machine / invariant tests

```typescript
describe('Order state transitions', () => {
  const validTransitions: [OrderStatus, string, OrderStatus][] = [
    [OrderStatus.Draft, 'place', OrderStatus.Placed],
    [OrderStatus.Placed, 'pay', OrderStatus.Paid],
    [OrderStatus.Paid, 'ship', OrderStatus.Shipped],
    [OrderStatus.Shipped, 'deliver', OrderStatus.Delivered],
    [OrderStatus.Placed, 'cancel', OrderStatus.Cancelled],
    [OrderStatus.Paid, 'cancel', OrderStatus.Cancelled],
  ]

  const invalidTransitions: [OrderStatus, string][] = [
    [OrderStatus.Placed, 'place'],
    [OrderStatus.Shipped, 'cancel'],
    [OrderStatus.Delivered, 'cancel'],
    [OrderStatus.Cancelled, 'place'],
  ]

  validTransitions.forEach(([from, action, to]) => {
    it(`${from} → ${action} → ${to}`, () => {
      const order = createOrderInStatus(from)
      const result = (order as any)[action]()
      expect(result.status).toBe(to)
    })
  })

  invalidTransitions.forEach(([from, action]) => {
    it(`${from} → ${action} → throws`, () => {
      const order = createOrderInStatus(from)
      expect(() => (order as any)[action]()).toThrow()
    })
  })
})
```

---

## Property-Based Testing

For domain invariants that should hold for ANY input.

### TypeScript (fast-check)

```typescript
import fc from 'fast-check'

describe('Money properties', () => {
  it('addition is commutative', () => {
    fc.assert(
      fc.property(
        fc.nat({ max: 1_000_000 }),
        fc.nat({ max: 1_000_000 }),
        (a, b) => {
          const moneyA = Money.of(a, 'JPY')
          const moneyB = Money.of(b, 'JPY')
          expect(moneyA.add(moneyB)).toEqual(moneyB.add(moneyA))
        }
      )
    )
  })

  it('adding zero is identity', () => {
    fc.assert(
      fc.property(
        fc.nat({ max: 1_000_000 }),
        (a) => {
          const money = Money.of(a, 'JPY')
          const zero = Money.of(0, 'JPY')
          expect(money.add(zero)).toEqual(money)
        }
      )
    )
  })
})

describe('Order invariants', () => {
  it('total always equals sum of item subtotals', () => {
    fc.assert(
      fc.property(
        fc.array(
          fc.record({
            productId: fc.string({ minLength: 1 }),
            quantity: fc.integer({ min: 1, max: 100 }),
            unitPrice: fc.integer({ min: 1, max: 100000 })
          }),
          { minLength: 1, maxLength: 20 }
        ),
        (items) => {
          const orderItems = items.map(i =>
            OrderItem.create(i.productId, i.quantity, Money.of(i.unitPrice, 'JPY'))
          )
          const order = Order.create(OrderId.generate(), CustomerId.generate(), orderItems)

          const expectedTotal = orderItems.reduce(
            (sum, item) => sum.add(item.subtotal),
            Money.of(0, 'JPY')
          )
          expect(order.totalAmount).toEqual(expectedTotal)
        }
      )
    )
  })
})
```

### Python (Hypothesis)

```python
from hypothesis import given, strategies as st

@given(
    amount_a=st.integers(min_value=0, max_value=1_000_000),
    amount_b=st.integers(min_value=0, max_value=1_000_000),
)
def test_money_addition_commutative(amount_a: int, amount_b: int) -> None:
    a = Money(amount=amount_a, currency="JPY")
    b = Money(amount=amount_b, currency="JPY")
    assert a.add(b) == b.add(a)

@given(
    items=st.lists(
        st.fixed_dictionaries({
            "product_id": st.text(min_size=1, max_size=10),
            "quantity": st.integers(min_value=1, max_value=100),
            "unit_price": st.integers(min_value=1, max_value=100000),
        }),
        min_size=1,
        max_size=20,
    )
)
def test_order_total_invariant(items: list[dict]) -> None:
    order_items = [
        OrderItem(product_id=i["product_id"], quantity=i["quantity"],
                  unit_price=Money(amount=i["unit_price"], currency="JPY"))
        for i in items
    ]
    order = Order.create(OrderId.generate(), order_items)
    expected = sum(item.subtotal.amount for item in order_items)
    assert order.total_amount.amount == expected
```
