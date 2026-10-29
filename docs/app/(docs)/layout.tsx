import type { ReactNode } from "react";
import Header from "@/components/Header";
import PrevNext from "@/components/PrevNext";
import Sidebar from "@/components/Sidebar";
import Toc from "@/components/Toc";
import Footer from "@/components/Footer";

export default function DocsLayout({ children }: { children: ReactNode }) {
  return (
    <>
      <Header docs />
      <div className="docs-shell">
        <Sidebar />
        <main className="docs-main">
          <article className="prose">{children}</article>
          <PrevNext />
          <Footer compact />
        </main>
        <aside className="docs-aside">
          <Toc />
        </aside>
      </div>
    </>
  );
}
