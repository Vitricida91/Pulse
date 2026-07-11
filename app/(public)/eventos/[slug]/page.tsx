import { PlaceholderPage } from "@/components/placeholder-page";

type PageProps = {
  params: Promise<{ slug: string }>;
};

export default async function EventoDetallePage({ params }: PageProps) {
  const { slug } = await params;

  return (
    <PlaceholderPage
      eyebrow={`Evento: ${slug}`}
      title="Página del evento — en construcción"
      description="Acá se mostrará la información completa del show y el inicio de la compra."
    />
  );
}
