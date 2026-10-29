import type { MDXComponents } from "mdx/types";
import Link from "next/link";
import type { ComponentPropsWithoutRef, ReactElement, ReactNode } from "react";
import { isValidElement } from "react";
import CodeBlock from "@/components/CodeBlock";
import { Callout, DevBadge, Kbd } from "@/components/Callout";
import Screenshot from "@/components/Screenshot";
import { slugify, textOf } from "@/lib/util";

function heading(Tag: "h2" | "h3" | "h4") {
  return function Heading({ children }: { children?: ReactNode }) {
    const id = slugify(textOf(children));
    return (
      <Tag id={id} className="anchor-heading">
        <a href={`#${id}`} className="anchor" aria-hidden="true" tabIndex={-1}>
          #
        </a>
        {children}
      </Tag>
    );
  };
}

function Pre({ children }: { children?: ReactNode }) {
  if (isValidElement(children)) {
    const props = (children as ReactElement<{ className?: string; children?: ReactNode }>).props;
    const lang = /language-([\w-]+)/.exec(props.className || "")?.[1];
    return <CodeBlock code={textOf(props.children)} lang={lang} />;
  }
  return <pre>{children}</pre>;
}

function A({ href = "", children, ...rest }: ComponentPropsWithoutRef<"a">) {
  if (href.startsWith("/")) return <Link href={href}>{children}</Link>;
  if (href.startsWith("#")) return <a href={href}>{children}</a>;
  return (
    <a href={href} target="_blank" rel="noreferrer" {...rest}>
      {children}
    </a>
  );
}

function Table(props: ComponentPropsWithoutRef<"table">) {
  return (
    <div className="table-wrap">
      <table {...props} />
    </div>
  );
}

const components: MDXComponents = {
  h2: heading("h2"),
  h3: heading("h3"),
  h4: heading("h4"),
  pre: Pre,
  a: A,
  table: Table,
  Callout,
  DevBadge,
  Kbd,
  Screenshot,
  CodeBlock,
};

export function useMDXComponents(other: MDXComponents = {}): MDXComponents {
  return { ...components, ...other };
}
