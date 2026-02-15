import {
  Bot,
  Globe,
  PawPrint,
  Sparkles,
  Terminal,
  Zap,
  type LucideIcon,
} from "lucide-react";

const ICON_MAP: Record<string, LucideIcon> = {
  bot: Bot,
  sparkles: Sparkles,
  zap: Zap,
  "paw-print": PawPrint,
  terminal: Terminal,
  globe: Globe,
};

interface AgentIconProps {
  name: string;
  size?: number;
  className?: string;
  style?: React.CSSProperties;
}

export function AgentIcon({ name, size = 16, className, style }: AgentIconProps) {
  const IconComponent = ICON_MAP[name] ?? Bot;
  return <IconComponent size={size} className={className} style={style} />;
}
