import { PlaceholderPage } from "@/components/placeholder-page";

type PageProps = {
  params: Promise<{ id: string }>;
};

export default async function AdminEventoDetallePage({ params }: PageProps) {
  const { id } = await params;

  return (
    <PlaceholderPage
      eyebrow={`Evento: ${id}`}
      title="Edición de evento — en construcción"
      description="Edición de evento y tipos de entrada. Se implementa en la Fase 2."
    />
  );
}
