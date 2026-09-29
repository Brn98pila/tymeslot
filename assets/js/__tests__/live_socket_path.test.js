import { liveSocketPath } from '../live_socket_path';
import { afterEach, describe, expect, test } from 'vitest';

// A stand-in window: `self`/`top` decide whether the page is framed, and the
// real jsdom document carries (or not) the server's embed marker.
function fakeWindow({ framed }) {
  const win = { document };
  win.self = win;
  win.top = framed ? {} : win;
  return win;
}

describe('liveSocketPath', () => {
  afterEach(() => {
    document.documentElement.removeAttribute('data-embed-served');
  });

  test('a top-level page not served as an embed uses /live', () => {
    expect(liveSocketPath(fakeWindow({ framed: false }))).toBe('/live');
  });

  test('a framed page uses /embed-live', () => {
    expect(liveSocketPath(fakeWindow({ framed: true }))).toBe('/embed-live');
  });

  test('a page served as an embed uses /embed-live even when not framed', () => {
    document.documentElement.setAttribute('data-embed-served', '');
    expect(liveSocketPath(fakeWindow({ framed: false }))).toBe('/embed-live');
  });
});
