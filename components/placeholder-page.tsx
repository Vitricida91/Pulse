type PlaceholderPageProps = {
  eyebrow: string;
  title: string;
  description: string;
};

/**
 * Marcador temporal de ruta. Se reemplaza por la interfaz definitiva
 * en la fase del roadmap correspondiente a cada sección.
 */
export function PlaceholderPage({ eyebrow, title, description }: PlaceholderPageProps) {
  return (
    <div className="flex flex-1 items-center justify-center px-6 py-24">
      <div className="max-w-md space-y-3 rounded-lg border border-border bg-surface p-8 text-center">
        <p className="text-xs font-medium tracking-widest text-accent uppercase">
          {eyebrow}
        </p>
        <h1 className="text-xl font-semibold text-foreground">{title}</h1>
        <p className="text-sm text-muted">{description}</p>
      </div>
    </div>
  );
}
