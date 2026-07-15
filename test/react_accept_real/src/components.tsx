import * as React from "react";

export interface ButtonProps {
  label: string;
  kind?: "primary" | "ghost";
  onPress?: () => void;
}

export function Button(props: ButtonProps) {
  return (
    <button className={props.kind ?? "primary"} onClick={props.onPress}>
      {props.label}
    </button>
  );
}

export interface PanelProps {
  title: string;
  children: React.ReactNode;
}

export function Panel(props: PanelProps) {
  return (
    <section>
      <h2>{props.title}</h2>
      {props.children}
    </section>
  );
}

export interface BadgeProps { count: number; max?: number; }

export class Badge extends React.Component<BadgeProps> {
  render() {
    const shown = this.props.max !== undefined && this.props.count > this.props.max
      ? "many"
      : String(this.props.count);
    return <span data-testid="badge">{shown}</span>;
  }
}
