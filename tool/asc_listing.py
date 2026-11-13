#!/usr/bin/env python3
"""Fills the Messages++ App Store listing through the App Store Connect API: app info
(subtitle, privacy policy), categories, age rating, content rights, version text,
App Review details, free price, worldwide availability, the build (when one has been
uploaded) and the screenshots in assets/store/ios.

    ASC_CONTACT_PHONE=+234... ASC_DEMO_CODE=... python3 tool/asc_listing.py [build number]

Re-runnable: each step updates what is there. Not set here (the API can't, or a person
should): App Privacy answers, the EU trader status, the Comeriver Pro subscriptions'
prices, and pressing "Submit for Review". The developer API is a web-only feature and is
deliberately not mentioned in the listing.
"""
import glob
import hashlib
import os
import sys
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from asc_api import APP_BUNDLE, call  # noqa: E402

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))
SHOTS = os.path.join(ROOT, 'assets', 'store', 'ios')
SITE = 'https://messages.comeriver.com'
with open(os.path.join(ROOT, 'pubspec.yaml')) as _pubspec:
    VERSION = next(line.split(':', 1)[1].strip().split('+')[0] for line in _pubspec if line.startswith('version:'))
_notes = os.path.join(ROOT, 'RELEASE_NOTES.txt')
WHATS_NEW = open(_notes).read().strip()[:4000] if os.path.exists(_notes) else ''

SUBTITLE = 'Group texts, chats & email'  # 26/30
PROMO = ('Write once, reach everyone: personal texts from your own number, free chats with Contacts++ '
         'members, and email, now or on a schedule.')
KEYWORDS = 'bulk sms,group text,mass text,broadcast,church,campaign,email,schedule,reminder,birthday,contacts'  # 97/100
DESCRIPTION = '''Messages++ lets you send personal messages to whole groups of your contacts, by text from your own number, as free Contacts++ chats, or by email, now or on a schedule.

YOUR CONTACTS, ALREADY HERE
• Use your phone's contacts directly: numbers, emails, birthdays and companies.
• Put people in groups: a choir, a class, your customers, your team.
• Import more from a CSV or Excel export.

REACH YOUR PEOPLE
• Write once and personalise with {first_name}, {company}, {birthday} and more.
• Preview the exact message each person gets, and how many SMS parts it uses.
• Texts open in Messages for you to review and tap Send, one person at a time or up to 20 at once.
• Emails go out by themselves through your own email service or your Gmail.

CHATS WITH CONTACTS++ MEMBERS
• Sign in with your free Contacts++ account (optional).
• People on Contacts++ who accept your messages get a free chat instead of a text, on every device they use, with no tap needed. Everyone else gets a text.
• Their replies arrive in Messages++ and in Contacts++.

BACK UP AND WRITE ON THE WEB
• Back up your contacts, groups, campaigns and texts to your Contacts++ account, and bring them to a new phone.
• Write messages on your computer at messages.comeriver.com; your phone sends them.

ON YOUR SCHEDULE
• Send once at a set time, or every week on the days you choose.
• Automatic birthday wishes (Pro).
• A reminder arrives when a scheduled campaign is due.

SEND SAFELY
• People who opt out are always left out.
• Follow every message: waiting, sent, delivered or failed, and send again to anyone who was missed.

WORKS WITH YOUR IPHONE
• "Messages++" in the share sheet, with recent chats suggested at the top.
• Siri and Spotlight shortcuts: new message, message a group, birthdays.

FREE, OR COMERIVER PRO
• Free: every feature, with "Sent via messages.comeriver.com" at the end of campaign messages, up to 5 saved campaigns, 1 schedule and 50 emails a day.
• Comeriver Pro ($2.00 a month, or $21.49 a year): unlimited campaigns and schedules, automatic birthday wishes, your own email limits, and your own signature or none.

Please only message people who have agreed to hear from you. Your carrier's normal SMS charges apply.

SUBSCRIPTIONS
Comeriver Pro is an optional auto-renewable subscription: Comeriver Pro Monthly (1 month, US$2.00 a month) or Comeriver Pro Yearly (1 year, US$21.49 a year, about 10% less than paying monthly). Prices in other countries are shown in the app before you buy. Payment is charged to your Apple Account when you confirm the purchase. It renews automatically unless cancelled at least 24 hours before the end of the current period; your account is charged for renewal within 24 hours before that. Manage or cancel it in your App Store account settings.

Terms of Use (EULA): https://www.apple.com/legal/internet-services/itunes/dev/stdeula/
Messages++ Terms: https://messages.comeriver.com/terms
Privacy Policy: https://messages.comeriver.com/privacy

Messages++ is made by Comeriver Limited.'''

REVIEW_NOTES = '''1. PURPOSE
Messages++ helps people send personal messages to groups of their own contacts: a church choir, a class, customers. On iPhone and iPad every text is sent by the user: each text (or a batch of up to 20) opens in Apple's Messages composer, where the user reviews it and taps Send. The app never sends texts by itself. Emails go through the user's own email service.

2. TRY IT WITHOUT AN ACCOUNT (no sign-in needed)
Contacts tab › Groups › New group, add yourself. Campaigns › New campaign › "Text (SMS)", message "Hello {first_name}", choose the group › Save and review › Open next message › tap Send in the composer.
Scheduling: on a campaign, Schedule… › a time 2 minutes ahead › Save (allow notifications). A reminder appears; tapping it opens the campaign ready to send.

3. OPTIONAL CONTACTS++ ACCOUNT (Settings › Contacts++ account)
Contacts++ is our own account service (also on the App Store). Signing in opens Contacts++ (or its website) to approve Messages++; Messages++ never sees the password. To review: Settings › Contacts++ account › Continue with Contacts++ › choose Nigeria (+234), number 8030000000, and the code in the Password field of these details. No SMS is sent.
Signed in, it adds: chats with Contacts++ members instead of texts (Messages tab › Chats), Backup and sync (Settings), and texts written at messages.comeriver.com that wait in the app for the user to tap Send.
Account deletion: Settings › Contacts++ account › Delete account.

4. OTHER
"Connect Gmail" (Settings › Email) uses Google sign-in only to send email from the user's own Gmail (gmail.send scope).
Comeriver Pro (Settings › Comeriver Pro) is optional; the free app is fully usable.
Share sheet: share text from Safari to "Messages++"; Siri/Spotlight: "New message in Messages++".

5. EXTERNAL SERVICES
Contacts++ API (our own, behind Cloudflare), Apple Push Notification service and Firebase Cloud Messaging, the user's chosen email service (Mailgun-compatible or Gmail), Apple In-App Purchase. No AI services. No ads or tracking.'''


def contacts_review_phone():
    """The App Review contact phone already on the Contacts++ record (same team), never printed."""
    try:
        cid = call('GET', '/v1/apps?filter[bundleId]=com.comeriver.contacts')['data'][0]['id']
        version = call('GET', f'/v1/apps/{cid}/appStoreVersions?filter[platform]=IOS&limit=1')['data'][0]
        detail = call('GET', f"/v1/appStoreVersions/{version['id']}/appStoreReviewDetail").get('data')
        return (detail or {}).get('attributes', {}).get('contactPhone')
    except (SystemExit, IndexError, KeyError):
        return None


def app_id():
    return call('GET', f'/v1/apps?filter[bundleId]={APP_BUNDLE}')['data'][0]['id']


FAILED = []


def step(name, fn):
    try:
        fn()
        print(f'✓ {name}')
    except SystemExit as error:
        print(f'✗ {name}: {error}')
        FAILED.append(name)


def main():
    build_number = sys.argv[1] if len(sys.argv) > 1 else None
    aid = app_id()
    info = next(i for i in call('GET', f'/v1/apps/{aid}/appInfos')['data']
                if i['attributes']['state'] != 'READY_FOR_DISTRIBUTION')
    versions = call('GET', f'/v1/apps/{aid}/appStoreVersions?filter[platform]=IOS')['data']
    version = next((v for v in versions if v['attributes']['appStoreState'] in (
        'PREPARE_FOR_SUBMISSION', 'READY_FOR_REVIEW', 'DEVELOPER_REJECTED', 'REJECTED', 'METADATA_REJECTED')), None)
    if version is None:
        version = call('POST', '/v1/appStoreVersions', {'data': {
            'type': 'appStoreVersions', 'attributes': {'platform': 'IOS', 'versionString': VERSION},
            'relationships': {'app': {'data': {'type': 'apps', 'id': aid}}}}})['data']
        print(f'Created App Store version {VERSION}')
    vid = version['id']
    released = any(v['attributes']['appStoreState'] == 'READY_FOR_SALE' for v in versions)

    def app_info_text():
        loc = call('GET', f"/v1/appInfos/{info['id']}/appInfoLocalizations")['data'][0]
        call('PATCH', f"/v1/appInfoLocalizations/{loc['id']}", {'data': {
            'type': 'appInfoLocalizations', 'id': loc['id'],
            'attributes': {'subtitle': SUBTITLE, 'privacyPolicyUrl': f'{SITE}/privacy'}}})

    def categories():
        call('PATCH', f"/v1/appInfos/{info['id']}", {'data': {'type': 'appInfos', 'id': info['id'], 'relationships': {
            'primaryCategory': {'data': {'type': 'appCategories', 'id': 'PRODUCTIVITY'}},
            'secondaryCategory': {'data': {'type': 'appCategories', 'id': 'BUSINESS'}}}}})

    def age_rating():
        rating = call('GET', f"/v1/appInfos/{info['id']}/ageRatingDeclaration")['data']
        none = {k: 'NONE' for k in [
            'alcoholTobaccoOrDrugUseOrReferences', 'contests', 'gamblingSimulated', 'gunsOrOtherWeapons',
            'medicalOrTreatmentInformation', 'profanityOrCrudeHumor', 'sexualContentGraphicAndNudity',
            'sexualContentOrNudity', 'horrorOrFearThemes', 'matureOrSuggestiveThemes',
            'violenceCartoonOrFantasy', 'violenceRealisticProlongedGraphicOrSadistic', 'violenceRealistic']}
        # Chats with Contacts++ members who accept messages from you; no public content.
        flags = {'advertising': False, 'ageAssurance': False, 'gambling': False, 'healthOrWellnessTopics': False,
                 'lootBox': False, 'messagingAndChat': True, 'parentalControls': False,
                 'unrestrictedWebAccess': False, 'userGeneratedContent': False, 'socialMedia': False}
        call('PATCH', f"/v1/ageRatingDeclarations/{rating['id']}", {'data': {
            'type': 'ageRatingDeclarations', 'id': rating['id'], 'attributes': {**none, **flags}}})

    def content_rights():
        call('PATCH', f'/v1/apps/{aid}', {'data': {'type': 'apps', 'id': aid, 'attributes': {
            'contentRightsDeclaration': 'DOES_NOT_USE_THIRD_PARTY_CONTENT'}}})

    def version_fields():
        call('PATCH', f'/v1/appStoreVersions/{vid}', {'data': {'type': 'appStoreVersions', 'id': vid, 'attributes': {
            'versionString': VERSION, 'copyright': '2026 Comeriver Limited', 'releaseType': 'AFTER_APPROVAL'}}})

    def version_text():
        for loc in call('GET', f'/v1/appStoreVersions/{vid}/appStoreVersionLocalizations')['data']:
            call('PATCH', f"/v1/appStoreVersionLocalizations/{loc['id']}", {'data': {
                'type': 'appStoreVersionLocalizations', 'id': loc['id'], 'attributes': {
                    'description': DESCRIPTION, 'keywords': KEYWORDS, 'promotionalText': PROMO,
                    'supportUrl': SITE, 'marketingUrl': SITE,
                    **({'whatsNew': WHATS_NEW} if released and WHATS_NEW else {})}}})

    def review_details():
        attributes = {'contactFirstName': 'Ayoola', 'contactLastName': 'Falola',
                      'contactEmail': 'messages@comeriver.com', 'notes': REVIEW_NOTES,
                      # The app works without an account; the demo account shows the Contacts++ features.
                      'demoAccountRequired': False, 'demoAccountName': '+2348030000000'}
        phone = os.environ.get('ASC_CONTACT_PHONE') or contacts_review_phone()
        if phone:
            attributes['contactPhone'] = phone
        if os.environ.get('ASC_DEMO_CODE'):
            attributes['demoAccountPassword'] = os.environ['ASC_DEMO_CODE']
        existing = call('GET', f'/v1/appStoreVersions/{vid}/appStoreReviewDetail').get('data')
        if existing:
            call('PATCH', f"/v1/appStoreReviewDetails/{existing['id']}", {'data': {
                'type': 'appStoreReviewDetails', 'id': existing['id'], 'attributes': attributes}})
        else:
            call('POST', '/v1/appStoreReviewDetails', {'data': {'type': 'appStoreReviewDetails', 'attributes': attributes,
                 'relationships': {'appStoreVersion': {'data': {'type': 'appStoreVersions', 'id': vid}}}}})

    def free_price():
        points = call('GET', f'/v1/apps/{aid}/appPricePoints?filter[territory]=USA&limit=200')['data']
        free = next(p for p in points if float(p['attributes']['customerPrice']) == 0)
        call('POST', '/v1/appPriceSchedules', {
            'data': {'type': 'appPriceSchedules', 'relationships': {
                'app': {'data': {'type': 'apps', 'id': aid}},
                'baseTerritory': {'data': {'type': 'territories', 'id': 'USA'}},
                'manualPrices': {'data': [{'type': 'appPrices', 'id': '${free}'}]}}},
            'included': [{'type': 'appPrices', 'id': '${free}', 'attributes': {'startDate': None},
                          'relationships': {'appPricePoint': {'data': {'type': 'appPricePoints', 'id': free['id']}}}}]})

    def availability():
        try:
            if call('GET', f'/v1/apps/{aid}/appAvailabilityV2').get('data'):
                print('  already set')
                return
        except SystemExit as error:
            if '(404)' not in str(error):
                raise  # 404: not set yet, so set it now
        territories = call('GET', '/v1/territories?limit=200')['data']
        refs = [{'type': 'territoryAvailabilities', 'id': f"${{{t['id']}}}"} for t in territories]
        call('POST', '/v2/appAvailabilities', {
            'data': {'type': 'appAvailabilities', 'attributes': {'availableInNewTerritories': True}, 'relationships': {
                'app': {'data': {'type': 'apps', 'id': aid}},
                'territoryAvailabilities': {'data': refs}}},
            'included': [{'type': 'territoryAvailabilities', 'id': f"${{{t['id']}}}", 'attributes': {'available': True},
                          'relationships': {'territory': {'data': {'type': 'territories', 'id': t['id']}}}}
                         for t in territories]})

    def build():
        query = f'/v1/builds?filter[app]={aid}&filter[processingState]=VALID&sort=-uploadedDate&limit=1'
        if build_number:
            query += f'&filter[version]={build_number}'
        found = call('GET', query)['data']
        if not found:
            raise SystemExit('no processed build yet: run tool/release_ios.sh, then this script again')
        chosen = found[0]
        if chosen['attributes'].get('usesNonExemptEncryption') is None:
            call('PATCH', f"/v1/builds/{chosen['id']}", {'data': {'type': 'builds', 'id': chosen['id'],
                 'attributes': {'usesNonExemptEncryption': False}}})
        call('PATCH', f'/v1/appStoreVersions/{vid}/relationships/build', {'data': {'type': 'builds', 'id': chosen['id']}})
        print(f"  build {chosen['attributes']['version']}")

    def screenshots():
        loc = call('GET', f'/v1/appStoreVersions/{vid}/appStoreVersionLocalizations')['data'][0]
        sets = {s['attributes']['screenshotDisplayType']: s['id']
                for s in call('GET', f"/v1/appStoreVersionLocalizations/{loc['id']}/appScreenshotSets")['data']}
        for display, prefix in (('APP_IPHONE_67', 'iphone'), ('APP_IPAD_PRO_3GEN_129', 'ipad')):
            files = sorted(glob.glob(os.path.join(SHOTS, f'{prefix}_*.png')))[:10]
            if not files:
                continue
            set_id = sets.get(display) or call('POST', '/v1/appScreenshotSets', {'data': {
                'type': 'appScreenshotSets', 'attributes': {'screenshotDisplayType': display},
                'relationships': {'appStoreVersionLocalization': {'data': {
                    'type': 'appStoreVersionLocalizations', 'id': loc['id']}}}}})['data']['id']
            existing = call('GET', f'/v1/appScreenshotSets/{set_id}/appScreenshots')['data']
            wanted = [hashlib.md5(open(path, 'rb').read()).hexdigest() for path in files]
            if [old['attributes'].get('sourceFileChecksum') for old in existing] == wanted:
                print(f'  {display}: {len(files)} screenshots, unchanged')
                continue
            for old in existing:
                call('DELETE', f"/v1/appScreenshots/{old['id']}")
            for path in files:
                data = open(path, 'rb').read()
                shot = call('POST', '/v1/appScreenshots', {'data': {'type': 'appScreenshots', 'attributes': {
                    'fileName': os.path.basename(path), 'fileSize': len(data)},
                    'relationships': {'appScreenshotSet': {'data': {'type': 'appScreenshotSets', 'id': set_id}}}}})['data']
                for op in shot['attributes']['uploadOperations']:
                    part = data[op['offset']:op['offset'] + op['length']]
                    request = urllib.request.Request(op['url'], data=part, method=op['method'],
                                                     headers={h['name']: h['value'] for h in op['requestHeaders']})
                    urllib.request.urlopen(request, timeout=120).read()
                call('PATCH', f"/v1/appScreenshots/{shot['id']}", {'data': {'type': 'appScreenshots', 'id': shot['id'],
                     'attributes': {'uploaded': True, 'sourceFileChecksum': hashlib.md5(data).hexdigest()}}})
            print(f'  {display}: {len(files)} screenshots')

    step('App info: subtitle, privacy policy', app_info_text)
    step('Categories: Productivity, Business', categories)
    step('Age rating', age_rating)
    step('Content rights', content_rights)
    step(f'Version {VERSION}: copyright, release after approval', version_fields)
    step('Description, keywords, promotional text, URLs', version_text)
    step('App Review contact and notes', review_details)
    step('Price: free', free_price)
    step('Availability: all territories', availability)
    step('Screenshots', screenshots)
    step('Build', build)


if __name__ == '__main__':
    main()
    if FAILED:
        sys.exit(f"Not done: {', '.join(FAILED)}")
