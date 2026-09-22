# NammaStayBackend
Namma Stay backend Code . Property of Circle Company (LLC)
# Namma Stay - Backend API Service ⚙️

The backend service for **Namma Stay**—a property and guest management system for modern hostels, boutique stays, and co-living spaces. It handles authentication, real-time bed inventory allocation, automated billing, guest ID processing, and notification pipelines.

---

## 📌 Versioning & Release Tracking

This service adheres strictly to **[Semantic Versioning (SemVer)](https://semver.org/)** (`MAJOR.MINOR.PATCH`).

* **Current API Version**: `v1.8.2`
* **API Base Endpoint**: `/api/v1`

### Versioning Protocol
* **MAJOR (`1.0.0` → `2.0.0`)**: Breaking API schema changes, endpoint deprecations, or major database structural overhauls.
* **MINOR (`1.8.0` → `1.9.0`)**: Backward-compatible new endpoints or feature additions (e.g., adding a new payment gateway driver).
* **PATCH (`1.8.1` → `1.8.2`)**: Backward-compatible security patches, performance improvements, and bug fixes.

---

## 🛠️ Required Resources & Tech Stack

### Core Runtime & Frameworks
* **Runtime Environment**: Node.js `v18.x.x` or `v20.x.x` (LTS recommended)
* **Framework**: Express.js `v4.18+` (TypeScript `v5.0+`)
* **Database**: PostgreSQL `v15+`
* **ORM**: Prisma `v5+` / TypeORM
* **In-Memory Cache & Queues**: Redis `v7.0+` (Session management, rate-limiting, background jobs)

### Third-Party Services & Integrations
* **Authentication**: JWT (JSON Web Tokens) with RSA-256 signatures & Refresh Token rotation.
* **Payment Gateways**: Razorpay / Stripe Node SDKs (webhooks enabled for async payment processing).
* **Cloud Storage**: AWS S3 or Google Cloud Storage (Encrypted bucket for guest ID document uploads).
* **Messaging & Notifications**: Twilio / Gupshup SDK (WhatsApp and SMS verification/check-in alerts).
* **Logging & Monitoring**: Winston / Pino logging with Sentry error tracking.

---

## 📂 Repository & Project Structure

```text
backend/
├── prisma/
│   ├── migrations/          # Database migration history
│   └── schema.prisma        # Database schema definitions
├── src/
│   ├── config/              # Database, Redis, and third-party API configs
│   ├── controllers/         # Request handlers & HTTP routing logic
│   ├── middleware/          # Auth guard, error handler, rate-limiter, validator
│   ├── models/              # Data models / Prisma client wrappers
│   ├── routes/              # Express API route modules (v1)
│   ├── services/            # Core business logic (Payments, Bookings, Notifications)
│   ├── utils/               # Shared helpers, loggers, and custom errors
│   └── app.ts               # Express app initialization
├── tests/                   # Integration and unit test suites (Jest / Supertest)
├── .env.example             # Template for local environment variables
├── package.json             # Dependencies and scripts (Version specified here)
└── tsconfig.json            # TypeScript configuration
