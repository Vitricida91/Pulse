import { PlaceholderPage } from "@/components/placeholder-page";

type PageProps = {
  params: Promise<{ eventId: string }>;
};

export default async function CheckoutPage({ params }: PageProps) {
  const { eventId } = await params;

  return (
    <PlaceholderPage
      eyebrow={`Checkout: ${eventId}`}
      title="Inicio de compra — en construcción"
      description="Acá se implementará la selección de entradas y los datos del comprador."
    />
  );
}
