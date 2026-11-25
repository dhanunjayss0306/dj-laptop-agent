// Request classifier. Port of src/main/v53/router.ts.
// Pure keyword rules. NOTE: this is NOT the live chat classifier —
// the live classifier is BrainService (lib/core/brain.dart). The
// router picks a service graph (ordered tool chain) per request type.
typedef RequestType = String; // 'file' | 'text' | 'voice' | 'image' | 'system'

class ClassifiedRequest {
  final String type;
  final double confidence;
  final List<String> route;
  const ClassifiedRequest(
      {required this.type, required this.confidence, required this.route});
}

const _imageWords = [
  'image', 'photo', 'picture', 'screenshot', 'jpg', 'jpeg', 'png', 'gif', 'webp'
];
const _fileWords = [
  'open', 'find', 'search', 'summar', 'organiz', 'duplicat', 'list',
  'file', 'folder', 'download'
];
const _systemWords = [
  'cpu', 'ram', 'memory usage', 'disk', 'battery', 'system info',
  'how much space', 'temperature'
];

ClassifiedRequest classifyRequest(String text,
    {bool hasImage = false, bool isVoice = false}) {
  final low = text.toLowerCase().trim();
  if (hasImage || _imageWords.any(low.contains)) {
    return ClassifiedRequest(
        type: 'image', confidence: 0.9, route: serviceGraphFor('image'));
  }
  if (isVoice) {
    return ClassifiedRequest(
        type: 'voice', confidence: 0.9, route: serviceGraphFor('voice'));
  }
  if (_systemWords.any(low.contains)) {
    return ClassifiedRequest(
        type: 'system', confidence: 0.85, route: serviceGraphFor('system'));
  }
  if (_fileWords.any(low.contains)) {
    return ClassifiedRequest(
        type: 'file', confidence: 0.8, route: serviceGraphFor('file'));
  }
  return ClassifiedRequest(
      type: 'text', confidence: 0.6, route: serviceGraphFor('text'));
}

/// The service graph for one request type: an ordered chain of DJ
/// tools. A step only runs when the previous step succeeded.
List<String> serviceGraphFor(String type) {
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
    default:
      return ['classify', 'answer'];
  }
}
