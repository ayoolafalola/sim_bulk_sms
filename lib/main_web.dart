
import 'package:flutter/material.dart';

void main() {
  runApp(const BulkSmsWebApp());
}

class BulkSmsWebApp extends StatelessWidget {
  const BulkSmsWebApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SIM Bulk SMS',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF176B57),
        ),
        scaffoldBackgroundColor: const Color(0xFFF6F8FA),
        inputDecorationTheme: const InputDecorationTheme(
          border: OutlineInputBorder(),
        ),
      ),
      home: const DashboardScreen(),
    );
  }
}

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  int selectedPage = 0;
  final messageController = TextEditingController();
  final campaignController = TextEditingController();

  final List<Map<String, String>> campaigns = [];
  final List<Map<String, String>> contacts = [];

  @override
  void dispose() {
    messageController.dispose();
    campaignController.dispose();
    super.dispose();
  }

  void createCampaign() {
    final name = campaignController.text.trim();
    final message = messageController.text.trim();

    if (name.isEmpty || message.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Enter a campaign name and message first.'),
        ),
      );
      return;
    }

    setState(() {
      campaigns.insert(0, {
        'name': name,
        'message': message,
        'status': 'Draft',
      });
      selectedPage = 2;
      campaignController.clear();
      messageController.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final pages = [
      dashboardPage(),
      contactsPage(),
      campaignsPage(),
      composePage(),
    ];

    return Scaffold(
      body: Row(
        children: [
          NavigationRail(
            extended: MediaQuery.sizeOf(context).width >= 900,
            backgroundColor: Colors.white,
            selectedIndex: selectedPage,
            onDestinationSelected: (index) {
              setState(() => selectedPage = index);
            },
            leading: const Padding(
              padding: EdgeInsets.symmetric(vertical: 28),
              child: Icon(
                Icons.mark_chat_unread_rounded,
                size: 34,
                color: Color(0xFF176B57),
              ),
            ),
            destinations: const [
              NavigationRailDestination(
                icon: Icon(Icons.dashboard_outlined),
                selectedIcon: Icon(Icons.dashboard),
                label: Text('Dashboard'),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.people_outline),
                selectedIcon: Icon(Icons.people),
                label: Text('Contacts'),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.campaign_outlined),
                selectedIcon: Icon(Icons.campaign),
                label: Text('Campaigns'),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.edit_note),
                selectedIcon: Icon(Icons.edit_note),
                label: Text('Compose SMS'),
              ),
            ],
          ),
          const VerticalDivider(width: 1),
          Expanded(
            child: Column(
              children: [
                Container(
                  height: 72,
                  padding: const EdgeInsets.symmetric(horizontal: 28),
                  color: Colors.white,
                  child: const Row(
                    children: [
                      Expanded(
                        child: Text(
                          'SIM Bulk SMS',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      Icon(Icons.computer_outlined),
                      SizedBox(width: 8),
                      Text('Web workspace'),
                    ],
                  ),
                ),
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(28),
                    child: pages[selectedPage],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget dashboardPage() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Dashboard',
          style: TextStyle(fontSize: 30, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        const Text('Manage contacts, prepare SMS campaigns and review drafts.'),
        const SizedBox(height: 28),
        LayoutBuilder(
          builder: (context, constraints) {
            final columns = constraints.maxWidth > 850 ? 3 : 1;
            final width =
                (constraints.maxWidth - (columns - 1) * 16) / columns;

            return Wrap(
              spacing: 16,
              runSpacing: 16,
              children: [
                statCard(
                  'Contacts in this session',
                  '${contacts.length}',
                  Icons.people_outline,
                  width,
                ),
                statCard(
                  'Campaign drafts',
                  '${campaigns.length}',
                  Icons.campaign_outlined,
                  width,
                ),
                statCard(
                  'Messages sent',
                  '0',
                  Icons.send_outlined,
                  width,
                ),
              ],
            );
          },
        ),
        const SizedBox(height: 28),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Get started',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 16),
                actionTile(
                  Icons.people_outline,
                  'Manage contacts',
                  'Start building your recipient list.',
                  () => setState(() => selectedPage = 1),
                ),
                actionTile(
                  Icons.edit_note,
                  'Compose a campaign',
                  'Write an SMS and save it as a draft.',
                  () => setState(() => selectedPage = 3),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 20),
        const Text(
          'Web preview: data is currently held in memory and will reset '
          'when you refresh the page. SMS sending is not enabled.',
          style: TextStyle(color: Colors.blueGrey),
        ),
      ],
    );
  }

  Widget statCard(String title, String value, IconData icon, double width) {
    return SizedBox(
      width: width,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(22),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, color: const Color(0xFF176B57), size: 28),
              const SizedBox(height: 18),
              Text(
                value,
                style: const TextStyle(
                  fontSize: 30,
                  fontWeight: FontWeight.bold,
                ),
              ),
              Text(title, style: const TextStyle(color: Colors.blueGrey)),
            ],
          ),
        ),
      ),
    );
  }

  Widget actionTile(
    IconData icon,
    String title,
    String subtitle,
    VoidCallback onTap,
  ) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon, color: const Color(0xFF176B57)),
      title: Text(title),
      subtitle: Text(subtitle),
      trailing: const Icon(Icons.arrow_forward_ios, size: 16),
      onTap: onTap,
    );
  }

  Widget contactsPage() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Contacts',
          style: TextStyle(fontSize: 30, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        const Text(
          'Recipient management workspace',
        ),
        const SizedBox(height: 24),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Add a contact',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _nameController,
                  decoration: const InputDecoration(labelText: 'Full name'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _phoneController,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(
                    labelText: 'Phone number',
                    hintText: '+2348012345678',
                  ),
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: () {
                    final name = _nameController.text.trim();
                    final phone = _phoneController.text.trim();

                    if (name.isEmpty || phone.isEmpty) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Enter a name and phone number.'),
                        ),
                      );
                      return;
                    }

                    setState(() {
                      contacts.add({'name': name, 'phone': phone});
                      _nameController.clear();
                      _phoneController.clear();
                    });
                  },
                  icon: const Icon(Icons.person_add_alt_1),
                  label: const Text('Add contact'),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 20),
        Text(
          'Contact list (${contacts.length})',
          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 12),
        if (contacts.isEmpty)
          const Card(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text('No contacts added in this session yet.'),
            ),
          )
        else
          ...contacts.map(
            (contact) => Card(
              child: ListTile(
                leading: const CircleAvatar(child: Icon(Icons.person)),
                title: Text(contact['name']!),
                subtitle: Text(contact['phone']!),
                trailing: IconButton(
                  tooltip: 'Remove contact',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => setState(() => contacts.remove(contact)),
                ),
              ),
            ),
          ),
      ],
    );
  }

  final _nameController = TextEditingController();
  final _phoneController = TextEditingController();

  Widget campaignsPage() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Campaigns',
          style: TextStyle(fontSize: 30, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        const Text('Review your saved campaign drafts.'),
        const SizedBox(height: 24),
        if (campaigns.isEmpty)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.drafts_outlined, size: 36),
                  const SizedBox(height: 12),
                  const Text('No campaign drafts yet.'),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: () => setState(() => selectedPage = 3),
                    child: const Text('Compose your first SMS'),
                  ),
                ],
              ),
            ),
          )
        else
          ...campaigns.map(
            (campaign) => Card(
              child: ListTile(
                leading: const CircleAvatar(
                  child: Icon(Icons.mark_chat_read_outlined),
                ),
                title: Text(campaign['name']!),
                subtitle: Text(
                  '${campaign['status']} · ${campaign['message']}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: IconButton(
                  tooltip: 'Delete draft',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => setState(() => campaigns.remove(campaign)),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget composePage() {
    final message = messageController.text;
    final segments = estimateSegments(message);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Compose SMS',
          style: TextStyle(fontSize: 30, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        const Text('Create a message and save it as a campaign draft.'),
        const SizedBox(height: 24),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: campaignController,
                  decoration: const InputDecoration(
                    labelText: 'Campaign name',
                    hintText: 'e.g. Customer announcement',
                  ),
                ),
                const SizedBox(height: 20),
                TextField(
                  controller: messageController,
                  minLines: 5,
                  maxLines: 10,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(
                    labelText: 'Message',
                    alignLabelWithHint: true,
                    hintText: 'Type your SMS message here...',
                  ),
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 24,
                  runSpacing: 8,
                  children: [
                    Text('Characters: ${message.length}'),
                    Text('Estimated SMS segments: $segments'),
                  ],
                ),
                const SizedBox(height: 8),
                const Text(
                  'Segment count is a rough preview. The project’s SMS '
                  'estimator should be integrated for accurate encoding rules.',
                  style: TextStyle(color: Colors.blueGrey),
                ),
                const SizedBox(height: 20),
                FilledButton.icon(
                  onPressed: createCampaign,
                  icon: const Icon(Icons.save_outlined),
                  label: const Text('Save campaign draft'),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  int estimateSegments(String message) {
    if (message.isEmpty) return 0;

    final gsmPattern = RegExp(
      r"^[\x00-\x7F]*$",
    );
    final isBasic = gsmPattern.hasMatch(message);
    final singleLimit = isBasic ? 160 : 70;
    final multipartLimit = isBasic ? 153 : 67;

    if (message.length <= singleLimit) return 1;
    return (message.length / multipartLimit).ceil();
  }
}