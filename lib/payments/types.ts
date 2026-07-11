/**
 * Contrato agnóstico al proveedor de pagos.
 *
 * La lógica de negocio (`lib/domain`, Route Handlers) nunca importa un
 * SDK de un proveedor concreto (ej. `import { MercadoPagoConfig } from
 * "mercadopago"`). Solo conoce estos tipos y la interfaz
 * `PaymentProvider`. Cada proveedor real (Mercado Pago en la Fase 3, y
 * eventualmente otros) se implementa como un adapter en
 * `lib/payments/<provider>/` que traduce entre su propio SDK/API y este
 * contrato.
 *
 * Ver DECISIONS.md → "Arquitectura de pagos agnóstica al proveedor"
 * para la justificación completa y las alternativas consideradas.
 */

/** Identificador de proveedor. Se extiende con una nueva literal cada
 * vez que se agrega un adapter real (Fase 3+: "mercadopago"; fases
 * posteriores: "bank_transfer", etc.). En la base de datos `provider`
 * es `text` a propósito (ver migración `schema_core.sql`), no un enum:
 * agregar un proveedor no debe requerir una migración. */
export type ProviderId = "mercadopago";

/** Estados normalizados de un hecho de pago — deben coincidir
 * exactamente con el enum `payment_status` de Postgres
 * (`supabase/migrations/20260711182551_schema_core.sql`). */
export type NormalizedPaymentStatus =
  | "PENDING"
  | "IN_PROGRESS"
  | "APPROVED"
  | "REJECTED"
  | "CANCELLED"
  | "REFUNDED"
  | "CHARGED_BACK";

/** Debe coincidir con el enum `payment_method_type` de Postgres. */
export type PaymentMethodType =
  | "credit_card"
  | "debit_card"
  | "digital_wallet"
  | "bank_transfer"
  | "cash"
  | "other";

export type Money = {
  amountCents: number;
  currency: string;
};

export type CreatePaymentSessionInput = {
  orderId: string;
  amount: Money;
  buyerName: string;
  buyerEmail: string;
  /** Descripción legible que el proveedor puede mostrarle al comprador. */
  description: string;
  successUrl: string;
  pendingUrl: string;
  failureUrl: string;
};

export type PaymentSessionResult = {
  /** Identificador de la sesión/preferencia/intento en el proveedor
   * (ej. `preference_id` de Mercado Pago). `null` para proveedores sin
   * concepto de sesión previa (ver `BankTransferProvider` más abajo). */
  externalSessionId: string | null;
  /** URL a la que redirigir al comprador para completar el pago. `null`
   * si el proveedor no tiene un paso de redirección (ej. instrucciones
   * de transferencia mostradas in-app). */
  redirectUrl: string | null;
};

export type NormalizedPaymentFact = {
  externalPaymentId: string;
  externalSessionId: string | null;
  /** El valor que nosotros le pasamos al proveedor como referencia de
   * nuestra orden (en general, `orderId`), tal como el proveedor lo
   * devuelve. Ver columna `payments.external_reference`. */
  externalReference: string | null;
  status: NormalizedPaymentStatus;
  /** Detalle textual del proveedor (ej. `status_detail` de Mercado
   * Pago), sanitizado — nunca el payload completo. Ver `payments.raw_provider_status`. */
  rawProviderStatus: string | null;
  amount: Money;
  paymentMethodType: PaymentMethodType | null;
  approvedAt: Date | null;
};

export type WebhookVerificationInput = {
  rawBody: string;
  headers: Headers;
};

export type WebhookVerificationResult =
  | { valid: true }
  | { valid: false; reason: string };

export type ParsedWebhookEvent = {
  /** Identificador único del evento de notificación en el proveedor,
   * usado para la idempotencia en `webhook_events`. */
  externalEventId: string;
  eventType: string;
  /** `null` si el evento no corresponde a un pago puntual (ej. un
   * evento de prueba). */
  externalPaymentId: string | null;
};

/**
 * Capacidades que un adapter puede o no ofrecer. No todos los
 * proveedores se comportan igual — ver "Diferencias entre proveedores"
 * más abajo — por eso la interfaz no obliga a todos a implementar lo
 * mismo.
 */
export type PaymentProviderCapabilities = {
  /**
   * `true` si el pago puede confirmarse en el mismo flujo de compra
   * (tarjeta, billetera virtual): el comprador ve el resultado en
   * minutos. `false` si el pago siempre queda pendiente de un paso
   * asíncrono/manual (ej. transferencia bancaria, boleto) — la orden
   * puede tardar horas o días en resolverse.
   */
  instantConfirmation: boolean;
  /**
   * `true` si el proveedor puede notificar un reembolso/contracargo vía
   * webhook después de la aprobación (permite sincronizar
   * `REFUNDED`/`CHARGED_BACK` automáticamente, ver
   * `record_payment_and_confirm_order`).
   */
  refundNotifications: boolean;
  /**
   * `true` si el proveedor soporta iniciar un reembolso mediante su
   * API. Ningún adapter del MVP lo implementa todavía: los reembolsos
   * se hacen manualmente desde el dashboard del proveedor (decisión de
   * la Fase 0.1). Sirve para que el panel admin sepa si puede ofrecer
   * "reembolsar desde acá" en el futuro.
   */
  programmaticRefunds: boolean;
};

/**
 * Contrato que debe implementar cada adapter de proveedor de pagos.
 *
 * Capacidades **obligatorias** (todo adapter las implementa, aunque el
 * resultado interno varíe): `createPaymentSession`, `getPaymentStatus`,
 * `verifyWebhookSignature`, `parseWebhookEvent`. Son el mínimo
 * indispensable para que la orden pueda pagarse y confirmarse.
 *
 * Capacidad **opcional**: `initiateRefund` — solo se implementa si
 * `capabilities.programmaticRefunds` es `true`.
 */
export type PaymentProvider = {
  readonly id: ProviderId;
  readonly capabilities: PaymentProviderCapabilities;

  createPaymentSession(input: CreatePaymentSessionInput): Promise<PaymentSessionResult>;

  /**
   * Re-consulta el estado real contra la API del proveedor. La capa que
   * llama a esto nunca debe confiar únicamente en el contenido de un
   * webhook (ver SECURITY.md).
   */
  getPaymentStatus(externalPaymentId: string): Promise<NormalizedPaymentFact>;

  verifyWebhookSignature(input: WebhookVerificationInput): WebhookVerificationResult;

  parseWebhookEvent(rawBody: string): ParsedWebhookEvent;

  /** Solo presente cuando `capabilities.programmaticRefunds` es `true`. */
  initiateRefund?(externalPaymentId: string): Promise<void>;
};

/**
 * Diferencias documentadas entre proveedores conocidos/previstos (no
 * implementados todavía salvo que se indique lo contrario):
 *
 * - **MercadoPagoProvider** (Fase 3, primer adapter real):
 *   `instantConfirmation: true`, `refundNotifications: true`,
 *   `programmaticRefunds: false` (por decisión de producto del MVP, no
 *   por limitación técnica de la API). `externalSessionId` = el
 *   `preference_id` de Checkout Pro. Cubre, según los medios que MP
 *   habilite para la cuenta, tarjetas de crédito/débito, dinero en
 *   cuenta y otras billeteras que MP integre — la disponibilidad real
 *   de cada medio depende de la configuración de la cuenta de Mercado
 *   Pago, no de este adapter.
 *
 * - **BankTransferProvider** (no implementado, arquitectura preparada):
 *   `instantConfirmation: false` — una transferencia no se confirma en
 *   el momento, la orden queda pendiente de acreditación/verificación
 *   manual antes de poder pasar a `APPROVED`. `externalSessionId` sería
 *   nulo o un número de referencia interno (no hay "sesión" en un
 *   proveedor externo). `refundNotifications: false` (no hay proveedor
 *   que notifique nada; un reembolso de una transferencia se gestiona
 *   100% manualmente). No tiene webhook real: la confirmación la
 *   dispara un admin desde el panel al verificar el comprobante — ese
 *   flujo, cuando se implemente, deberá decidir cómo encaja con
 *   `record_payment_and_confirm_order` sin forzar la interfaz de
 *   `PaymentProvider` a asumir que siempre existe un webhook.
 */
