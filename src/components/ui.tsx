// Small shared pieces so every "working…" state looks and sounds the same.

export function Spinner({ className = "" }: { className?: string }) {
  return <span aria-hidden="true" className={`kami-spinner ${className}`} />;
}

// Thin bar across the top of the screen while something is happening.
export function ProgressBar() {
  return <div aria-hidden="true" className="kami-progress" />;
}

// Tells screen readers what is going on without moving focus.
export function LiveStatus({ children }: { children: React.ReactNode }) {
  return (
    <p role="status" aria-live="polite" className="sr-only">
      {children}
    </p>
  );
}
