// DJ v3 tests — rules brain. Every command form the user uses.

import { describe, expect, it } from 'vitest';

import {
  BrainService,
  parseOrganizeRange,
  parseOrganizeRangeText,
  rangeLabel,
} from '../src/main/services/brainService';

const brain = new BrainService();

describe('decide: search', () => {
  it('find <topic> searches', () => {
    expect(brain.decide('find my Virun pitch')).toEqual({
      action: 'search',
      query: 'my Virun pitch',
    });
  });
  it('search for <topic> searches', () => {
    expect(brain.decide('search for my resume')).toEqual({
      action: 'search',
      query: 'my resume',
    });
  });
  it('where is <topic> searches', () => {
    expect(brain.decide('where is my resume')).toEqual({
      action: 'search',
      query: 'my resume',
    });
  });
  it('look for <topic> searches', () => {
    expect(brain.decide('look for my Virun pitch')).toEqual({
      action: 'search',
      query: 'my Virun pitch',
    });
  });
  it('show me <topic> searches', () => {
    expect(brain.decide('show me my Virun pitch')).toEqual({
      action: 'search',
      query: 'my Virun pitch',
    });
  });
  it('a bare topic defaults to search', () => {
    expect(brain.decide('Virun pitch')).toEqual({ action: 'search', query: 'Virun pitch' });
  });
});

describe('decide: open', () => {
  it('open <file> opens it', () => {
    expect(brain.decide('open my Virun pitch')).toEqual({
      action: 'open',
      query: 'my Virun pitch',
    });
  });
  it('open something about <topic> strips the filler words', () => {
    expect(brain.decide('open something about travel and tourism')).toEqual({
      action: 'open',
      query: 'travel and tourism',
    });
  });
  it('open all the things about <topic> strips the filler words', () => {
    expect(brain.decide('open all the things about travel')).toEqual({
      action: 'open',
      query: 'travel',
    });
  });
});

describe('decide: open apps', () => {
  it.each([
    ['open notepad', 'notepad'],
    ['open chrome', 'chrome'],
    ['open calculator', 'calculator'],
    ['open paint', 'paint'],
    ['open word', 'word'],
    ['open excel', 'excel'],
    ['open vs code', 'vs code'],
    ['open spotify', 'spotify'],
    ['open whatsapp', 'whatsapp'],
    ['open clock', 'clock'],
    ['open settings', 'settings'],
  ])('%s opens the app', (text, app) => {
    expect(brain.decide(text)).toEqual({ action: 'openApp', query: app });
  });
});

describe('decide: summarize', () => {
  it('summarize <file>', () => {
    expect(brain.decide('summarize my Virun pitch')).toEqual({
      action: 'summarize',
      query: 'my virun pitch',
    });
  });
  it('summarise (British spelling) works too', () => {
    expect(brain.decide('summarise my notes')).toEqual({
      action: 'summarize',
      query: 'my notes',
    });
  });
  it('summary of <file>', () => {
    expect(brain.decide('summary of my Virun pitch')).toEqual({
      action: 'summarize',
      query: 'my virun pitch',
    });
  });
});

describe('decide: organize', () => {
  it("organize yesterday's Downloads", () => {
    expect(brain.decide("organize yesterday's Downloads")).toEqual({
      action: 'organize',
      query: 'yesterday',
    });
  });
  it('organize last 3 days', () => {
    expect(brain.decide('organize last 3 days')).toEqual({
      action: 'organize',
      query: 'last 3 days',
    });
  });
  it('organize this week', () => {
    expect(brain.decide('organize this week')).toEqual({
      action: 'organize',
      query: 'last 7 days',
    });
  });
  it('organize everything', () => {
    expect(brain.decide('organize everything')).toEqual({
      action: 'organize',
      query: 'all',
    });
  });
  it('organize with no range returns an empty query (UI asks)', () => {
    expect(brain.decide('organize Downloads')).toEqual({ action: 'organize', query: '' });
  });
});

describe('decide: duplicates', () => {
  it('find duplicates', () => {
    expect(brain.decide('find duplicates')).toEqual({ action: 'duplicates', query: '' });
  });
  it('delete the extra copies', () => {
    expect(brain.decide('delete the extra copies')).toEqual({
      action: 'duplicates',
      query: 'delete',
    });
  });
  it('merge the extra copies', () => {
    expect(brain.decide('merge the extra copies')).toEqual({
      action: 'duplicates',
      query: 'merge',
    });
  });
  it('same file phrasing', () => {
    expect(brain.decide('do I have the same file twice')).toEqual({
      action: 'duplicates',
      query: '',
    });
  });
});

describe('decide: list and help', () => {
  it('list recent files', () => {
    expect(brain.decide('list recent files')).toEqual({
      action: 'list',
      query: 'list recent files',
    });
  });
  it('help', () => {
    expect(brain.decide('help')).toEqual({ action: 'help', query: '' });
  });
  it('what can you do', () => {
    expect(brain.decide('what can you do')).toEqual({ action: 'help', query: '' });
  });
  it('empty message shows help', () => {
    expect(brain.decide('   ')).toEqual({ action: 'help', query: '' });
  });
});

describe('parseOrganizeRangeText', () => {
  it.each([
    ['organize today', 'today'],
    ["organize yesterday's downloads", 'yesterday'],
    ['organize last 3 days', 'last 3 days'],
    ['organize past 5 days', 'last 5 days'],
    ['organize this week', 'last 7 days'],
    ['organize everything', 'all'],
    ['organize all files', 'all'],
  ])('%s -> %s', (text, expected) => {
    expect(parseOrganizeRangeText(text)).toBe(expected);
  });
  it('no range mentioned -> null', () => {
    expect(parseOrganizeRangeText('organize downloads')).toBeNull();
  });
});

describe('parseOrganizeRange', () => {
  it('today', () => expect(parseOrganizeRange('today')).toEqual({ kind: 'today' }));
  it('yesterday', () => expect(parseOrganizeRange('yesterday')).toEqual({ kind: 'yesterday' }));
  it('last 3 days', () =>
    expect(parseOrganizeRange('last 3 days')).toEqual({ kind: 'lastDays', days: 3 }));
  it('last 1 day (singular)', () =>
    expect(parseOrganizeRange('last 1 day')).toEqual({ kind: 'lastDays', days: 1 }));
  it('this week = last 7 days', () =>
    expect(parseOrganizeRange('last 7 days')).toEqual({ kind: 'lastDays', days: 7 }));
  it('all', () => expect(parseOrganizeRange('all')).toEqual({ kind: 'all' }));
  it('everything', () => expect(parseOrganizeRange('everything')).toEqual({ kind: 'all' }));
  it('no range -> null', () => expect(parseOrganizeRange('banana')).toBeNull());
});

describe('rangeLabel', () => {
  it('labels every range in plain words', () => {
    expect(rangeLabel({ kind: 'today' })).toBe('today');
    expect(rangeLabel({ kind: 'yesterday' })).toBe('yesterday');
    expect(rangeLabel({ kind: 'lastDays', days: 3 })).toBe('the last 3 days');
    expect(rangeLabel({ kind: 'lastDays', days: 1 })).toBe('the last 1 day');
    expect(rangeLabel({ kind: 'all' })).toBe('all files');
  });
});
