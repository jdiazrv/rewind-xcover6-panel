const test = require('node:test');
const assert = require('node:assert/strict');

const { bearingDistance, isOutsideZone, acceptsRevision } =
  require('./index')._test;

test('circle and sector containment match the app rules', () => {
  const insideNorth = { latitude: 37.0001, longitude: 23 };
  assert.equal(
    isOutsideZone(37, 23, insideNorth.latitude, insideNorth.longitude, {
      type: 'circle', radius: 20,
    }),
    false,
  );
  assert.equal(
    isOutsideZone(37, 23, insideNorth.latitude, insideNorth.longitude, {
      type: 'sector', radius: 20, startDeg: 90, endDeg: 270,
    }),
    true,
  );
});

test('distance is finite and symmetric', () => {
  const ab = bearingDistance(37, 23, 37.01, 23.02);
  const ba = bearingDistance(37.01, 23.02, 37, 23);
  assert.ok(Number.isFinite(ab.distanceM));
  assert.ok(Math.abs(ab.distanceM - ba.distanceM) < 0.001);
});

test('older device revisions cannot overwrite the latest anchor state', () => {
  assert.equal(acceptsRevision(2000, 1999), false);
  assert.equal(acceptsRevision(2000, 2000), true);
  assert.equal(acceptsRevision(2000, 2001), true);
  assert.equal(acceptsRevision(2000, Number.NaN), false);
});
