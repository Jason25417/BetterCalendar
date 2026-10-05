import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "个人状态接入",
  description: "查看设备接入与 Dot 的状态记录。",
  other: {
    "codex-preview": "development",
  },
  icons: {
    icon: "/favicon.svg",
    shortcut: "/favicon.svg",
  },
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="zh-CN">
      <body className="antialiased">{children}</body>
    </html>
  );
}
