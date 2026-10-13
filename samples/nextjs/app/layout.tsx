import type { Metadata } from 'next';
import type { ReactNode } from 'react';

export const metadata: Metadata = {
  title: '2wai avatar — Next.js sample',
  description: 'Split-plane reference: server route mints, client streams.',
};

export default function RootLayout({ children }: { children: ReactNode }) {
  return (
    <html lang="en">
      <head>
        <meta name="color-scheme" content="dark" />
        <style dangerouslySetInnerHTML={{ __html: `
          * { box-sizing: border-box; }
          body {
            margin: 0; min-height: 100vh;
            background: #0d0d12; color: #eaeaf0;
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
            display: flex; flex-direction: column; align-items: center;
            padding: 24px 16px 48px;
          }
        `}} />
      </head>
      <body>{children}</body>
    </html>
  );
}
