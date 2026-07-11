/**
 * Tipos del esquema de Postgres, escritos a mano a partir de las
 * migraciones en supabase/migrations/ (no se pudo usar
 * `supabase gen types` porque este entorno no tiene acceso a Docker;
 * ver informe de cierre de la Fase 1).
 *
 * Regenerar contra un proyecto real apenas esté disponible:
 *   supabase gen types typescript --linked > lib/data/database.types.ts
 *
 * Si se regenera, este archivo debe seguir siendo consistente con las
 * migraciones — son la fuente de verdad del esquema.
 */

export type Json = string | number | boolean | null | { [key: string]: Json | undefined } | Json[];

export type Database = {
  public: {
    Tables: {
      profiles: {
        Row: {
          id: string;
          name: string;
          email: string;
          role: Database["public"]["Enums"]["profile_role"];
          active: boolean;
          created_at: string;
        };
        Insert: {
          id: string;
          name: string;
          email: string;
          role: Database["public"]["Enums"]["profile_role"];
          active?: boolean;
          created_at?: string;
        };
        Update: Partial<Database["public"]["Tables"]["profiles"]["Insert"]>;
      };
      events: {
        Row: {
          id: string;
          title: string;
          slug: string;
          description: string | null;
          venue: string;
          city: string;
          event_date: string;
          doors_open: string | null;
          image_url: string | null;
          status: Database["public"]["Enums"]["event_status"];
          created_by: string | null;
          created_at: string;
          updated_at: string;
        };
        Insert: {
          id?: string;
          title: string;
          slug: string;
          description?: string | null;
          venue: string;
          city: string;
          event_date: string;
          doors_open?: string | null;
          image_url?: string | null;
          status?: Database["public"]["Enums"]["event_status"];
          created_by?: string | null;
          created_at?: string;
          updated_at?: string;
        };
        Update: Partial<Database["public"]["Tables"]["events"]["Insert"]>;
      };
      ticket_types: {
        Row: {
          id: string;
          event_id: string;
          name: string;
          description: string | null;
          price_cents: number;
          capacity: number;
          reserved: number;
          sold: number;
          max_per_order: number;
          sales_start: string | null;
          sales_end: string | null;
          status: Database["public"]["Enums"]["ticket_type_status"];
          created_at: string;
          updated_at: string;
        };
        Insert: {
          id?: string;
          event_id: string;
          name: string;
          description?: string | null;
          price_cents: number;
          capacity: number;
          reserved?: number;
          sold?: number;
          max_per_order?: number;
          sales_start?: string | null;
          sales_end?: string | null;
          status?: Database["public"]["Enums"]["ticket_type_status"];
          created_at?: string;
          updated_at?: string;
        };
        Update: Partial<Database["public"]["Tables"]["ticket_types"]["Insert"]>;
      };
      orders: {
        Row: {
          id: string;
          buyer_name: string;
          buyer_email: string;
          buyer_phone: string | null;
          status: Database["public"]["Enums"]["order_status"];
          currency: string;
          total_amount_cents: number;
          idempotency_key: string;
          request_fingerprint: string;
          mercado_pago_preference_id: string | null;
          requires_review_reason: string | null;
          expires_at: string | null;
          created_at: string;
          updated_at: string;
          paid_at: string | null;
        };
        Insert: {
          id?: string;
          buyer_name: string;
          buyer_email: string;
          buyer_phone?: string | null;
          status?: Database["public"]["Enums"]["order_status"];
          currency?: string;
          total_amount_cents: number;
          idempotency_key: string;
          request_fingerprint: string;
          mercado_pago_preference_id?: string | null;
          requires_review_reason?: string | null;
          expires_at?: string | null;
          created_at?: string;
          updated_at?: string;
          paid_at?: string | null;
        };
        Update: Partial<Database["public"]["Tables"]["orders"]["Insert"]>;
      };
      stock_reservations: {
        Row: {
          id: string;
          order_id: string;
          ticket_type_id: string;
          quantity: number;
          status: Database["public"]["Enums"]["reservation_status"];
          expires_at: string;
          created_at: string;
          released_at: string | null;
          converted_at: string | null;
        };
        Insert: {
          id?: string;
          order_id: string;
          ticket_type_id: string;
          quantity: number;
          status?: Database["public"]["Enums"]["reservation_status"];
          expires_at: string;
          created_at?: string;
          released_at?: string | null;
          converted_at?: string | null;
        };
        Update: Partial<Database["public"]["Tables"]["stock_reservations"]["Insert"]>;
      };
      order_items: {
        Row: {
          id: string;
          order_id: string;
          ticket_type_id: string;
          quantity: number;
          unit_price_cents: number;
          created_at: string;
        };
        Insert: {
          id?: string;
          order_id: string;
          ticket_type_id: string;
          quantity: number;
          unit_price_cents: number;
          created_at?: string;
        };
        Update: Partial<Database["public"]["Tables"]["order_items"]["Insert"]>;
      };
      payments: {
        Row: {
          id: string;
          order_id: string;
          provider: string;
          external_payment_id: string;
          status: Database["public"]["Enums"]["payment_status"];
          status_detail: string | null;
          amount_cents: number;
          currency: string;
          payment_method: string | null;
          external_reference: string | null;
          created_at: string;
          approved_at: string | null;
          updated_at: string;
        };
        Insert: {
          id?: string;
          order_id: string;
          provider?: string;
          external_payment_id: string;
          status: Database["public"]["Enums"]["payment_status"];
          status_detail?: string | null;
          amount_cents: number;
          currency?: string;
          payment_method?: string | null;
          external_reference?: string | null;
          created_at?: string;
          approved_at?: string | null;
          updated_at?: string;
        };
        Update: Partial<Database["public"]["Tables"]["payments"]["Insert"]>;
      };
      tickets: {
        Row: {
          id: string;
          order_id: string;
          order_item_id: string | null;
          event_id: string;
          ticket_type_id: string;
          public_token: string;
          short_code: string;
          status: Database["public"]["Enums"]["ticket_status"];
          issued_at: string;
          used_at: string | null;
          validated_by: string | null;
          validation_device: string | null;
          created_at: string;
        };
        Insert: {
          id?: string;
          order_id: string;
          order_item_id?: string | null;
          event_id: string;
          ticket_type_id: string;
          public_token: string;
          short_code: string;
          status?: Database["public"]["Enums"]["ticket_status"];
          issued_at?: string;
          used_at?: string | null;
          validated_by?: string | null;
          validation_device?: string | null;
          created_at?: string;
        };
        Update: Partial<Database["public"]["Tables"]["tickets"]["Insert"]>;
      };
      access_logs: {
        Row: {
          id: string;
          ticket_id: string | null;
          event_id: string | null;
          scanner_user_id: string | null;
          result: Database["public"]["Enums"]["access_result"];
          scanner_device: string | null;
          attempted_token: string | null;
          created_at: string;
        };
        Insert: {
          id?: string;
          ticket_id?: string | null;
          event_id?: string | null;
          scanner_user_id?: string | null;
          result: Database["public"]["Enums"]["access_result"];
          scanner_device?: string | null;
          attempted_token?: string | null;
          created_at?: string;
        };
        Update: Partial<Database["public"]["Tables"]["access_logs"]["Insert"]>;
      };
      webhook_events: {
        Row: {
          id: string;
          provider: string;
          external_event_id: string;
          event_type: string;
          payload: Json;
          signature_valid: boolean;
          processing_status: Database["public"]["Enums"]["webhook_processing_status"];
          attempts: number;
          created_at: string;
          processed_at: string | null;
        };
        Insert: {
          id?: string;
          provider?: string;
          external_event_id: string;
          event_type: string;
          payload: Json;
          signature_valid: boolean;
          processing_status?: Database["public"]["Enums"]["webhook_processing_status"];
          attempts?: number;
          created_at?: string;
          processed_at?: string | null;
        };
        Update: Partial<Database["public"]["Tables"]["webhook_events"]["Insert"]>;
      };
      recovery_tokens: {
        Row: {
          id: string;
          token_hash: string;
          buyer_email: string;
          status: Database["public"]["Enums"]["recovery_token_status"];
          expires_at: string;
          created_at: string;
          used_at: string | null;
        };
        Insert: {
          id?: string;
          token_hash: string;
          buyer_email: string;
          status?: Database["public"]["Enums"]["recovery_token_status"];
          expires_at: string;
          created_at?: string;
          used_at?: string | null;
        };
        Update: Partial<Database["public"]["Tables"]["recovery_tokens"]["Insert"]>;
      };
      email_logs: {
        Row: {
          id: string;
          order_id: string | null;
          ticket_id: string | null;
          type: Database["public"]["Enums"]["email_type"];
          recipient: string;
          provider_message_id: string | null;
          status: Database["public"]["Enums"]["email_status"];
          created_at: string;
        };
        Insert: {
          id?: string;
          order_id?: string | null;
          ticket_id?: string | null;
          type: Database["public"]["Enums"]["email_type"];
          recipient: string;
          provider_message_id?: string | null;
          status?: Database["public"]["Enums"]["email_status"];
          created_at?: string;
        };
        Update: Partial<Database["public"]["Tables"]["email_logs"]["Insert"]>;
      };
      admin_audit_logs: {
        Row: {
          id: string;
          actor_id: string | null;
          action: string;
          entity_type: string;
          entity_id: string | null;
          metadata: Json;
          created_at: string;
        };
        Insert: {
          id?: string;
          actor_id?: string | null;
          action: string;
          entity_type: string;
          entity_id?: string | null;
          metadata?: Json;
          created_at?: string;
        };
        Update: Partial<Database["public"]["Tables"]["admin_audit_logs"]["Insert"]>;
      };
    };
    Enums: {
      profile_role: "admin" | "scanner";
      event_status: "draft" | "published" | "unpublished" | "cancelled";
      ticket_type_status: "active" | "inactive";
      reservation_status: "ACTIVE" | "RELEASED" | "EXPIRED" | "CONVERTED";
      order_status:
        | "PENDING_PAYMENT"
        | "PAID"
        | "PAID_REQUIRES_REVIEW"
        | "CANCELLED"
        | "EXPIRED"
        | "REFUNDED";
      payment_status:
        | "pending"
        | "approved"
        | "authorized"
        | "in_process"
        | "in_mediation"
        | "rejected"
        | "cancelled"
        | "refunded"
        | "charged_back";
      ticket_status: "VALID" | "USED" | "CANCELLED" | "REFUNDED";
      access_result: "GRANTED" | "DENIED_USED" | "DENIED_INVALID" | "DENIED_CANCELLED";
      webhook_processing_status: "pending" | "processed" | "failed" | "ignored";
      recovery_token_status: "ACTIVE" | "USED" | "EXPIRED";
      email_type: "purchase_confirmation" | "ticket_delivery" | "recovery_link";
      email_status: "queued" | "sent" | "failed";
    };
    Functions: {
      // _try_issue_tickets_for_order es una función interna de uso
      // exclusivo desde otras funciones SQL: no se expone acá a
      // propósito para que el código de la app no la invoque
      // directamente vía RPC.
      create_order_with_reservation: {
        Args: {
          p_buyer_name: string;
          p_buyer_email: string;
          p_buyer_phone: string | null;
          p_idempotency_key: string;
          p_items: Json;
          p_reservation_minutes?: number;
        };
        Returns: {
          order_id: string;
          order_status: Database["public"]["Enums"]["order_status"];
          total_amount_cents: number;
          is_new: boolean;
        }[];
      };
      expire_stale_reservations: {
        Args: Record<string, never>;
        Returns: number;
      };
      release_reservation_for_order: {
        Args: { p_order_id: string };
        Returns: undefined;
      };
      confirm_order_paid: {
        Args: { p_order_id: string };
        Returns: {
          order_status: Database["public"]["Enums"]["order_status"];
          tickets_issued: boolean;
        }[];
      };
      issue_tickets_after_review: {
        Args: { p_order_id: string };
        Returns: {
          order_status: Database["public"]["Enums"]["order_status"];
          tickets_issued: boolean;
        }[];
      };
      validate_ticket: {
        Args: {
          p_public_token: string;
          p_scanner_id: string | null;
          p_device?: string | null;
        };
        Returns: {
          result: Database["public"]["Enums"]["access_result"];
          ticket_id: string | null;
          event_id: string | null;
          ticket_type_name: string | null;
          buyer_name: string | null;
          used_at: string | null;
        }[];
      };
    };
  };
};
