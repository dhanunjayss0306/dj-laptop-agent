// Tests for the cloud provider picker (lib/ui/app_state.dart).
//
// Verifies the picker wiring without any network:
// - every provider name maps to the right CloudProvider enum value;
// - an unknown provider name falls back to Gemini (the free default)
//   and never reaches the Worker;
// - each provider has the right free default model;
// - a saved model name wins over the default, an empty one does not;
// - the vision model is the provider default (Gemini's default is
//   multimodal, so screen Q&A works with it).

import 'package:dj/core/worker_client.dart';
import 'package:dj/ui/app_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('cloud provider mapping', () {
    test('providerFor maps all six providers', () {
      expect(DjAppState.providerFor('gemini'), CloudProvider.gemini);
      expect(DjAppState.providerFor('groq'), CloudProvider.groq);
      expect(DjAppState.providerFor('nvidia'), CloudProvider.nvidia);
      expect(DjAppState.providerFor('openai'), CloudProvider.openai);
      expect(DjAppState.providerFor('openrouter'), CloudProvider.openrouter);
      expect(DjAppState.providerFor('anthropic'), CloudProvider.anthropic);
    });

    test('providerFor falls back to Gemini for unknown names', () {
      expect(DjAppState.providerFor('bogus'), CloudProvider.gemini);
      expect(DjAppState.providerFor(''), CloudProvider.gemini);
      expect(DjAppState.providerFor('GEMINI'), CloudProvider.gemini);
    });

    test('default provider is Gemini', () {
      expect(const CloudSettings().provider, 'gemini');
      expect(const CloudSettings().model, '');
    });
  });

  group('default cloud models', () {
    test('free defaults per provider', () {
      expect(DjAppState.defaultCloudModel('gemini'), 'gemini-3.8-flash');
      expect(DjAppState.defaultCloudModel('groq'), 'openai/gpt-oss-120b');
      expect(
        DjAppState.defaultCloudModel('nvidia'),
        'nvidia/nemotron-3-super-120b-a12b',
      );
    });

    test('paid providers keep their defaults', () {
      expect(DjAppState.defaultCloudModel('openai'), 'gpt-4o');
      expect(DjAppState.defaultCloudModel('openrouter'), 'gpt-4o');
      expect(
        DjAppState.defaultCloudModel('anthropic'),
        'claude-sonnet-4-5',
      );
    });

    test('unknown provider defaults to gpt-4o (never crashes)', () {
      expect(DjAppState.defaultCloudModel('bogus'), 'gpt-4o');
    });
  });

  group('effective cloud model', () {
    test('saved model wins over the default', () {
      const settings = CloudSettings(provider: 'gemini', model: 'gemini-3.6-flash');
      expect(
        DjAppState.effectiveCloudModel(settings),
        'gemini-3.6-flash',
      );
    });

    test('empty model falls back to the provider default', () {
      const settings = CloudSettings(provider: 'groq', model: '');
      expect(
        DjAppState.effectiveCloudModel(settings),
        'openai/gpt-oss-120b',
      );
      const blank = CloudSettings(provider: 'nvidia', model: '   ');
      expect(
        DjAppState.effectiveCloudModel(blank),
        'nvidia/nemotron-3-super-120b-a12b',
      );
    });

    test('model name is trimmed', () {
      const settings = CloudSettings(
        provider: 'gemini',
        model: '  gemini-3.8-flash  ',
      );
      expect(
        DjAppState.effectiveCloudModel(settings),
        'gemini-3.8-flash',
      );
    });
  });

  group('vision model', () {
    test('vision model is the provider default', () {
      expect(DjAppState.visionModelFor('gemini'), 'gemini-3.8-flash');
      expect(DjAppState.visionModelFor('anthropic'), 'claude-sonnet-4-5');
      expect(DjAppState.visionModelFor('openai'), 'gpt-4o');
      expect(DjAppState.visionModelFor('groq'), 'openai/gpt-oss-120b');
      expect(
        DjAppState.visionModelFor('nvidia'),
        'nvidia/nemotron-3-super-120b-a12b',
      );
    });
  });
}
