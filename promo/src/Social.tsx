import { AbsoluteFill, Img, staticFile } from "remotion";
import { SANS } from "./fonts";

/** GitHub social preview (1280×640): the break screen, tilted, beside the pitch. */
export const Social: React.FC = () => (
  <AbsoluteFill
    style={{
      backgroundColor: "#07080b",
      backgroundImage:
        "radial-gradient(55% 60% at 18% 30%, rgba(122,162,247,0.22), transparent 70%), radial-gradient(45% 55% at 78% 40%, rgba(125,207,255,0.18), transparent 70%)",
      fontFamily: SANS,
      perspective: 1600,
    }}
  >
    <Img
      src={staticFile("rest.png")}
      style={{
        position: "absolute",
        left: 560,
        top: 70,
        width: 900,
        borderRadius: 12,
        rotate: "y -18deg",
        boxShadow: "0 0 0 1px rgba(255,255,255,0.1), 0 40px 100px rgba(0,0,0,0.7)",
      }}
    />
    <div style={{ position: "absolute", left: 80, top: 150, width: 520 }}>
      <div style={{ display: "flex", alignItems: "center", gap: 22 }}>
        <Img src={staticFile("icon.png")} style={{ borderRadius: "23%", width: 96, height: 96 }} />
        <div style={{ fontSize: 104, fontWeight: 800, letterSpacing: -4, color: "#f5f6f8" }}>Sich</div>
      </div>
      <div style={{ marginTop: 28, fontSize: 44, fontWeight: 700, letterSpacing: -1, lineHeight: 1.15, color: "#f2f3f5" }}>
        Many agents. One focus. Questions wait for <span style={{ color: "#7dcfff" }}>your break</span>.
      </div>
      <div style={{ marginTop: 22, fontSize: 26, fontWeight: 500, color: "rgba(230,233,240,0.6)" }}>
        A calm kanban and pomodoro for Claude Code, Codex and Cursor sessions.
      </div>
    </div>
  </AbsoluteFill>
);
