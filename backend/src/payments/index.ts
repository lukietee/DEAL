import { randomBytes } from "node:crypto";
import Stripe from "stripe";

export interface ChargeInput {
  amount: number; // cents
  currency: string;
  description: string;
  metadata: Record<string, string>;
  idempotencyKey: string;
}

export interface ChargeResult {
  id: string; // Stripe PaymentIntent id (pi_...)
  status: string; // "succeeded"
  mock: boolean;
}

export interface Payments {
  readonly kind: "stripe" | "mock";
  charge(input: ChargeInput): Promise<ChargeResult>;
}

/** Stripe test mode: create + confirm a PaymentIntent server-side with the Visa test card. */
export class StripePayments implements Payments {
  readonly kind = "stripe" as const;
  private stripe: Stripe;
  constructor(secretKey: string) {
    // Test mode only: a standard (sk_test_) or restricted (rk_test_, needs PaymentIntents: Write) key.
    if (!/^(sk|rk)_test_/.test(secretKey)) {
      throw new Error("STRIPE_SECRET_KEY must be a test-mode key (sk_test_... or rk_test_...)");
    }
    this.stripe = new Stripe(secretKey);
  }
  async charge(input: ChargeInput): Promise<ChargeResult> {
    const pi = await this.stripe.paymentIntents.create(
      {
        amount: input.amount,
        currency: input.currency,
        payment_method: "pm_card_visa",
        automatic_payment_methods: { enabled: true, allow_redirects: "never" },
        confirm: true,
        description: input.description,
        metadata: input.metadata,
      },
      { idempotencyKey: input.idempotencyKey },
    );
    if (pi.status !== "succeeded") throw new Error(`Stripe PaymentIntent ${pi.id} status ${pi.status}`);
    return { id: pi.id, status: pi.status, mock: false };
  }
}

/** No STRIPE_SECRET_KEY: fake but well-formed receipt. */
export class MockPayments implements Payments {
  readonly kind = "mock" as const;
  async charge(): Promise<ChargeResult> {
    return { id: `pi_mock_${randomBytes(12).toString("hex")}`, status: "succeeded", mock: true };
  }
}

export function createPayments(secretKey: string): Payments {
  return secretKey ? new StripePayments(secretKey) : new MockPayments();
}
