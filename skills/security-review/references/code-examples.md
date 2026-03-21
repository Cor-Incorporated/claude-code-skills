# Security Review - Code Examples

## Secrets Management

```typescript
// BAD: hardcoded secret
const apiKey = "sk-proj-xxxxx"

// GOOD: environment variable with validation
const apiKey = process.env.OPENAI_API_KEY
if (!apiKey) throw new Error('OPENAI_API_KEY not configured')
```

## Input Validation (Zod)

```typescript
import { z } from 'zod'

const CreateUserSchema = z.object({
  email: z.string().email(),
  name: z.string().min(1).max(100),
  age: z.number().int().min(0).max(150)
})

export async function createUser(input: unknown) {
  const validated = CreateUserSchema.parse(input)
  return await db.users.create(validated)
}
```

## File Upload Validation

```typescript
function validateFileUpload(file: File) {
  const maxSize = 5 * 1024 * 1024
  if (file.size > maxSize) throw new Error('File too large (max 5MB)')

  const allowedTypes = ['image/jpeg', 'image/png', 'image/gif']
  if (!allowedTypes.includes(file.type)) throw new Error('Invalid file type')

  const allowedExtensions = ['.jpg', '.jpeg', '.png', '.gif']
  const ext = file.name.toLowerCase().match(/\.[^.]+$/)?.[0]
  if (!ext || !allowedExtensions.includes(ext)) throw new Error('Invalid file extension')
}
```

## SQL Injection Prevention

```typescript
// BAD: string concatenation
const query = `SELECT * FROM users WHERE email = '${userEmail}'`

// GOOD: parameterized
const { data } = await supabase.from('users').select('*').eq('email', userEmail)

// GOOD: raw SQL with params
await db.query('SELECT * FROM users WHERE email = $1', [userEmail])
```

## Auth: JWT in httpOnly Cookies

```typescript
// BAD: localStorage
localStorage.setItem('token', token)

// GOOD: httpOnly cookie
res.setHeader('Set-Cookie',
  `token=${token}; HttpOnly; Secure; SameSite=Strict; Max-Age=3600`)
```

## Authorization Check

```typescript
export async function deleteUser(userId: string, requesterId: string) {
  const requester = await db.users.findUnique({ where: { id: requesterId } })
  if (requester.role !== 'admin') {
    return NextResponse.json({ error: 'Unauthorized' }, { status: 403 })
  }
  await db.users.delete({ where: { id: userId } })
}
```

## Row Level Security (Supabase)

```sql
ALTER TABLE users ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users view own data" ON users FOR SELECT USING (auth.uid() = id);
CREATE POLICY "Users update own data" ON users FOR UPDATE USING (auth.uid() = id);
```

## XSS: Sanitize HTML

```typescript
import DOMPurify from 'isomorphic-dompurify'

function renderUserContent(html: string) {
  const clean = DOMPurify.sanitize(html, {
    ALLOWED_TAGS: ['b', 'i', 'em', 'strong', 'p'],
    ALLOWED_ATTR: []
  })
  return <div dangerouslySetInnerHTML={{ __html: clean }} />
}
```

## CSP Headers

```typescript
// next.config.js
const securityHeaders = [{
  key: 'Content-Security-Policy',
  value: `default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data: https:; font-src 'self'; connect-src 'self' https://api.example.com;`.trim()
}]
```

## CSRF Token

```typescript
export async function POST(request: Request) {
  const token = request.headers.get('X-CSRF-Token')
  if (!csrf.verify(token)) {
    return NextResponse.json({ error: 'Invalid CSRF token' }, { status: 403 })
  }
}
```

## Rate Limiting

```typescript
import rateLimit from 'express-rate-limit'

const limiter = rateLimit({ windowMs: 15 * 60 * 1000, max: 100 })
app.use('/api/', limiter)

const searchLimiter = rateLimit({ windowMs: 60 * 1000, max: 10 })
app.use('/api/search', searchLimiter)
```

## Error Messages

```typescript
// BAD: leaking internals
catch (error) {
  return NextResponse.json({ error: error.message, stack: error.stack }, { status: 500 })
}

// GOOD: generic message
catch (error) {
  console.error('Internal error:', error)
  return NextResponse.json({ error: 'An error occurred. Please try again.' }, { status: 500 })
}
```

## Blockchain: Wallet Verification (Solana)

```typescript
import { verify } from '@solana/web3.js'

async function verifyWalletOwnership(publicKey: string, signature: string, message: string) {
  try {
    return verify(Buffer.from(message), Buffer.from(signature, 'base64'), Buffer.from(publicKey, 'base64'))
  } catch { return false }
}
```

## Security Test Examples

```typescript
test('requires authentication', async () => {
  const response = await fetch('/api/protected')
  expect(response.status).toBe(401)
})

test('requires admin role', async () => {
  const response = await fetch('/api/admin', {
    headers: { Authorization: `Bearer ${userToken}` }
  })
  expect(response.status).toBe(403)
})

test('rejects invalid input', async () => {
  const response = await fetch('/api/users', {
    method: 'POST',
    body: JSON.stringify({ email: 'not-an-email' })
  })
  expect(response.status).toBe(400)
})
```

## Resources

- [OWASP Top 10](https://owasp.org/www-project-top-ten/)
- [Next.js Security](https://nextjs.org/docs/security)
- [Supabase Security](https://supabase.com/docs/guides/auth)
- [Web Security Academy](https://portswigger.net/web-security)
