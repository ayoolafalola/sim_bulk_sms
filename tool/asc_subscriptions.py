#!/usr/bin/env python3
"""Creates (or updates) the Comeriver Pro subscriptions for Messages++ on the App Store:
the "Comeriver Pro" group, `comeriver_pro_monthly` and `comeriver_pro_yearly`, their text,
prices in every territory (Apple's equalised prices from the US price), availability and
the review screenshot.

    python3 tool/asc_subscriptions.py            # apply
    python3 tool/asc_subscriptions.py --dry-run  # show the chosen US price points only

Pricing: $2.00 a month; yearly is 10% less than twelve months (12 × 2.00 × 0.9 = 21.60).
Apple only allows its own price points, so the nearest one to each target is used.
Re-runnable. The subscriptions are submitted with the first app version (App Store
Connect › version › In-App Purchases and Subscriptions).
"""
import hashlib
import os
import sys
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from asc_api import APP_BUNDLE, call  # noqa: E402

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))
MONTHLY_USD = 2.00
YEARLY_DISCOUNT = 0.10
YEARLY_USD = round(MONTHLY_USD * 12 * (1 - YEARLY_DISCOUNT), 2)
REVIEW_SHOT = os.path.join(ROOT, 'assets', 'store', 'ios', 'iphone_7.png')
GROUP = 'Comeriver Pro'
DESCRIPTION = 'Unlimited campaigns, schedules and your own signature'  # ≤ 55
PRODUCTS = [
    ('comeriver_pro_monthly', 'Comeriver Pro Monthly', 'ONE_MONTH', MONTHLY_USD, 'Comeriver Pro (monthly)'),
    ('comeriver_pro_yearly', 'Comeriver Pro Yearly', 'ONE_YEAR', YEARLY_USD, 'Comeriver Pro (yearly, save 10%)'),
]
REVIEW_NOTE = ('Comeriver Pro unlocks unlimited campaigns and schedules, automatic birthday wishes, your own email '
               'limits and your own campaign signature (Settings › Comeriver Pro). The free app is fully usable.')


def all_pages(path):
    out = []
    while path:
        page = call('GET', path)
        out += page['data']
        nxt = page.get('links', {}).get('next')
        path = nxt.replace('https://api.appstoreconnect.apple.com', '') if nxt else None
    return out


def nearest_point(sub_id, territory, target):
    points = all_pages(f'/v1/subscriptions/{sub_id}/pricePoints?filter[territory]={territory}&limit=200')
    return min(points, key=lambda p: abs(float(p['attributes']['customerPrice']) - target))


def ensure_group(aid):
    groups = call('GET', f'/v1/apps/{aid}/subscriptionGroups')['data']
    group = next((g for g in groups if g['attributes']['referenceName'] == GROUP), None)
    if not group:
        group = call('POST', '/v1/subscriptionGroups', {'data': {'type': 'subscriptionGroups',
                     'attributes': {'referenceName': GROUP},
                     'relationships': {'app': {'data': {'type': 'apps', 'id': aid}}}}})['data']
        print(f'✓ Created group {GROUP}')
    locs = call('GET', f"/v1/subscriptionGroups/{group['id']}/subscriptionGroupLocalizations")['data']
    if not any(l['attributes']['locale'] == 'en-US' for l in locs):
        call('POST', '/v1/subscriptionGroupLocalizations', {'data': {'type': 'subscriptionGroupLocalizations',
             'attributes': {'locale': 'en-US', 'name': GROUP, 'customAppName': 'Messages++'},
             'relationships': {'subscriptionGroup': {'data': {'type': 'subscriptionGroups', 'id': group['id']}}}}})
    return group['id']


def ensure_subscription(group_id, product_id, name, period, display):
    subs = call('GET', f'/v1/subscriptionGroups/{group_id}/subscriptions')['data']
    sub = next((s for s in subs if s['attributes']['productId'] == product_id), None)
    if not sub:
        sub = call('POST', '/v1/subscriptions', {'data': {'type': 'subscriptions', 'attributes': {
            'name': name, 'productId': product_id, 'subscriptionPeriod': period, 'familySharable': False,
            'groupLevel': 1 if period == 'ONE_YEAR' else 2, 'reviewNote': REVIEW_NOTE},
            'relationships': {'group': {'data': {'type': 'subscriptionGroups', 'id': group_id}}}}})['data']
        print(f'✓ Created {product_id}')
    else:
        call('PATCH', f"/v1/subscriptions/{sub['id']}", {'data': {'type': 'subscriptions', 'id': sub['id'],
             'attributes': {'reviewNote': REVIEW_NOTE}}})
    locs = call('GET', f"/v1/subscriptions/{sub['id']}/subscriptionLocalizations")['data']
    loc = next((l for l in locs if l['attributes']['locale'] == 'en-US'), None)
    attrs = {'name': display, 'description': DESCRIPTION}
    if loc:
        call('PATCH', f"/v1/subscriptionLocalizations/{loc['id']}", {'data': {
            'type': 'subscriptionLocalizations', 'id': loc['id'], 'attributes': attrs}})
    else:
        call('POST', '/v1/subscriptionLocalizations', {'data': {'type': 'subscriptionLocalizations',
             'attributes': {'locale': 'en-US', **attrs},
             'relationships': {'subscription': {'data': {'type': 'subscriptions', 'id': sub['id']}}}}})
    return sub['id']


def set_prices(sub_id, target):
    base = nearest_point(sub_id, 'USA', target)
    print(f"  US price {base['attributes']['customerPrice']} (target {target:.2f})")
    existing = call('GET', f'/v1/subscriptions/{sub_id}/prices?include=subscriptionPricePoint&limit=200')
    current = {p['relationships']['subscriptionPricePoint']['data']['id'] for p in existing['data']
               if p.get('relationships', {}).get('subscriptionPricePoint', {}).get('data')}
    points = [base] + all_pages(f"/v1/subscriptionPricePoints/{base['id']}/equalizations?limit=200")
    added = 0
    for point in points:
        if point['id'] in current:
            continue
        call('POST', '/v1/subscriptionPrices', {'data': {'type': 'subscriptionPrices',
             'attributes': {'startDate': None, 'preserveCurrentPrice': False},
             'relationships': {'subscription': {'data': {'type': 'subscriptions', 'id': sub_id}},
                               'subscriptionPricePoint': {'data': {'type': 'subscriptionPricePoints', 'id': point['id']}}}}})
        added += 1
    print(f'  prices: {added} territories set ({len(points)} in all)')


def set_availability(sub_id):
    try:
        if call('GET', f'/v1/subscriptions/{sub_id}/subscriptionAvailability').get('data'):
            return
    except SystemExit as error:
        if '(404)' not in str(error):
            raise
    territories = call('GET', '/v1/territories?limit=200')['data']
    call('POST', '/v1/subscriptionAvailabilities', {'data': {'type': 'subscriptionAvailabilities',
         'attributes': {'availableInNewTerritories': True},
         'relationships': {'subscription': {'data': {'type': 'subscriptions', 'id': sub_id}},
                           'availableTerritories': {'data': [{'type': 'territories', 'id': t['id']} for t in territories]}}}})


def set_review_screenshot(sub_id):
    try:
        if call('GET', f'/v1/subscriptions/{sub_id}/appStoreReviewScreenshot').get('data'):
            return
    except SystemExit as error:
        if '(404)' not in str(error):
            raise
    data = open(REVIEW_SHOT, 'rb').read()
    shot = call('POST', '/v1/subscriptionAppStoreReviewScreenshots', {'data': {
        'type': 'subscriptionAppStoreReviewScreenshots',
        'attributes': {'fileName': os.path.basename(REVIEW_SHOT), 'fileSize': len(data)},
        'relationships': {'subscription': {'data': {'type': 'subscriptions', 'id': sub_id}}}}})['data']
    for op in shot['attributes']['uploadOperations']:
        part = data[op['offset']:op['offset'] + op['length']]
        request = urllib.request.Request(op['url'], data=part, method=op['method'],
                                         headers={h['name']: h['value'] for h in op['requestHeaders']})
        urllib.request.urlopen(request, timeout=120).read()
    call('PATCH', f"/v1/subscriptionAppStoreReviewScreenshots/{shot['id']}", {'data': {
        'type': 'subscriptionAppStoreReviewScreenshots', 'id': shot['id'],
        'attributes': {'uploaded': True, 'sourceFileChecksum': hashlib.md5(data).hexdigest()}}})


def main():
    dry = '--dry-run' in sys.argv
    aid = call('GET', f'/v1/apps?filter[bundleId]={APP_BUNDLE}')['data'][0]['id']
    group = ensure_group(aid) if not dry else None
    failed = []
    for product_id, name, period, target, display in PRODUCTS:
        if dry:
            print(f'{product_id}: target ${target:.2f}')
            continue
        try:
            sub = ensure_subscription(group, product_id, name, period, display)
            print(f'✓ {product_id}')
            # Apple refuses prices in territories the subscription isn't available in yet.
            set_availability(sub)
            print('  availability: all territories')
            set_prices(sub, target)
            set_review_screenshot(sub)
            print('  review screenshot')
        except SystemExit as error:
            print(f'✗ {product_id}: {error}')
            failed.append(product_id)
    if failed:
        sys.exit(f"Not done: {', '.join(failed)}")


if __name__ == '__main__':
    main()
