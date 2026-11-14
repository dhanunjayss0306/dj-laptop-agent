// DJ v5.3 — Lucida inclusion: the IDEA ONLY, no Lucida code.
// Lucida (Clarity Lab, 2014-2016, unmaintained since Dec 2022) is
// too old to reuse: Thrift 0.9.2, Caffe, pre-LLM retrieval. What DJ
// takes from it is one pattern: a query classifier picks a service
// graph — a small ordered chain of tools — from the request type.
// DJ's classifier is plain keyword rules, and its graphs are DJ's
// own tools. Nothing from Lucida's code, services, or stack is
// copied, and Lucida is never treated as a dependency.

export type RequestType = 'file' | 'text' | 'voice' | 'image' | 'system';

export interface ClassifiedRequest {
  type: RequestType;
  /** 0-1, how sure the classifier is. Below 0.5, DJ asks. */
  confidence: number;
  /** The ordered tool chain for this type. */
  route: string[];
}

const IMAGE_WORDS = ['image', 'photo', 'picture', 'screenshot', 'jpg', 'jpeg', 'png', 'gif', 'webp'];
const FILE_WORDS = ['open', 'find', 'search', 'summar', 'organiz', 'duplicat', 'list', 'file', 'folder', 'download'];
const SYSTEM_WORDS = ['cpu', 'ram', 'memory usage', 'disk', 'battery', 'system info', 'how much space', 'temperature'];

/** Route a request to the right tool chain by its type. Pure rules. */
export function classifyRequest(
  text: string,
  opts: { hasImage?: boolean; isVoice?: boolean } = {},
): ClassifiedRequest {
  const low = (text || '').toLowerCase().trim();
  if (opts.hasImage || IMAGE_WORDS.some((w) => low.includes(w))) {
    return { type: 'image', confidence: 0.9, route: serviceGraphFor('image') };
  }
  if (opts.isVoice) {
    return { type: 'voice', confidence: 0.9, route: serviceGraphFor('voice') };
  }
  if (SYSTEM_WORDS.some((w) => low.includes(w))) {
    return { type: 'system', confidence: 0.85, route: serviceGraphFor('system') };
  }
  if (FILE_WORDS.some((w) => low.includes(w))) {
    return { type: 'file', confidence: 0.8, route: serviceGraphFor('file') };
  }
  return { type: 'text', confidence: 0.6, route: serviceGraphFor('text') };
}

/** The service graph for one request type: an ordered chain of DJ
 *  tools. A step only runs when the previous step succeeded. */
export function serviceGraphFor(type: RequestType): string[] {
  switch (type) {
    case 'file':
      return ['classify', 'search', 'open'];
    case 'text':
      return ['classify', 'answer'];
    case 'voice':
      return ['transcribe', 'classify', 'answer', 'speak'];
    case 'image':
      return ['read-image', 'describe', 'search'];
    case 'system':
      return ['classify', 'system-info'];
  }
}
