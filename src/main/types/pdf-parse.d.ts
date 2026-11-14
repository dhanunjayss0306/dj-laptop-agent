// pdf-parse ships no TypeScript types. Minimal declaration for the
// API DJ uses: parse a Buffer, optionally with a custom pagerender
// (pdf-parse 1.1.4, options.pagerender replaces the default page
// renderer; options.max caps the pages rendered).
declare module 'pdf-parse' {
  export interface PdfParseResult {
    text: string;
    numpages: number;
    info?: Record<string, unknown>;
    metadata?: unknown;
  }
  export interface PdfParseOptions {
    pagerender?: (pageData: {
      getTextContent: (opts: {
        normalizeWhitespace: boolean;
        disableCombineTextItems: boolean;
      }) => Promise<{ items: { str: string; transform: number[] }[] }>;
    }) => Promise<string>;
    max?: number;
    version?: string;
  }
  const pdfParse: (data: Buffer, options?: PdfParseOptions) => Promise<PdfParseResult>;
  export default pdfParse;
}
