import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import '../../../constants/app_colors.dart';

class ContactShareData {
  final String name;
  final String phone;
  final String? email;
  final Uint8List? photo;

  const ContactShareData({
    required this.name,
    required this.phone,
    this.email,
    this.photo,
  });

  Map<String, dynamic> toJson() => {
    'name': name,
    'phone': phone,
    'email': email ?? '',
  };

  factory ContactShareData.fromJson(Map<String, dynamic> json) => ContactShareData(
    name: json['name']?.toString() ?? 'Kişi',
    phone: json['phone']?.toString() ?? '',
    email: json['email']?.toString(),
  );
}

class ContactPickerSheet extends StatefulWidget {
  const ContactPickerSheet({super.key});

  static Future<ContactShareData?> show(BuildContext context) {
    return showModalBottomSheet<ContactShareData>(
      context: context,
      backgroundColor: AppColors.surface,
      isScrollControlled: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => const ContactPickerSheet(),
    );
  }

  @override
  State<ContactPickerSheet> createState() => _ContactPickerSheetState();
}

class _ContactPickerSheetState extends State<ContactPickerSheet> {
  final TextEditingController _searchController = TextEditingController();
  List<Contact> _allContacts = [];
  List<Contact> _filteredContacts = [];
  bool _isLoading = true;
  bool _hasPermission = true;

  @override
  void initState() {
    super.initState();
    _loadContacts();
    _searchController.addListener(_onSearchChanged);
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadContacts() async {
    try {
      bool permission = await FlutterContacts.requestPermission(readonly: true);
      if (!permission) {
        if (mounted) {
          setState(() {
            _hasPermission = false;
            _isLoading = false;
          });
        }
        return;
      }

      final contacts = await FlutterContacts.getContacts(
        withProperties: true,
        withPhoto: true,
      );

      // Filter only contacts with at least one phone number and sort by name
      final validContacts = contacts
          .where((c) => c.phones.isNotEmpty && c.displayName.trim().isNotEmpty)
          .toList()
        ..sort((a, b) => a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()));

      if (mounted) {
        setState(() {
          _allContacts = validContacts;
          _filteredContacts = validContacts;
          _isLoading = false;
          _hasPermission = true;
        });
      }
    } catch (e) {
      debugPrint('[CONTACT PICKER ERR] $e');
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  void _onSearchChanged() {
    final query = _searchController.text.trim().toLowerCase();
    setState(() {
      if (query.isEmpty) {
        _filteredContacts = _allContacts;
      } else {
        _filteredContacts = _allContacts.where((contact) {
          final nameMatch = contact.displayName.toLowerCase().contains(query);
          final phoneMatch = contact.phones.any((p) => p.number.replaceAll(' ', '').contains(query));
          return nameMatch || phoneMatch;
        }).toList();
      }
    });
  }

  void _selectContact(Contact contact) {
    if (contact.phones.isEmpty) return;

    if (contact.phones.length == 1) {
      final shareData = ContactShareData(
        name: contact.displayName.trim(),
        phone: contact.phones.first.number.trim(),
        email: contact.emails.isNotEmpty ? contact.emails.first.address : null,
        photo: contact.photo,
      );
      Navigator.pop(context, shareData);
    } else {
      // Multiple numbers: ask user which one to share
      showModalBottomSheet(
        context: context,
        backgroundColor: AppColors.surfaceLight,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        builder: (ctx) {
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${contact.displayName} için Numara Seçin',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 12),
                  ...contact.phones.map((phone) {
                    final cleanNum = phone.number.trim();
                    return ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const CircleAvatar(
                        radius: 18,
                        backgroundColor: Colors.white12,
                        child: Icon(Icons.phone_rounded, color: AppColors.primaryLight, size: 18),
                      ),
                      title: Text(
                        cleanNum,
                        style: const TextStyle(color: Colors.white, fontSize: 14.5, fontWeight: FontWeight.w600),
                      ),
                      subtitle: Text(
                        phone.label.name.toUpperCase(),
                        style: const TextStyle(color: Colors.white54, fontSize: 11),
                      ),
                      trailing: const Icon(Icons.send_rounded, color: AppColors.primaryLight, size: 18),
                      onTap: () {
                        Navigator.pop(ctx);
                        final shareData = ContactShareData(
                          name: contact.displayName.trim(),
                          phone: cleanNum,
                          email: contact.emails.isNotEmpty ? contact.emails.first.address : null,
                          photo: contact.photo,
                        );
                        Navigator.pop(context, shareData);
                      },
                    );
                  }),
                ],
              ),
            ),
          );
        },
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.85,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, scrollController) {
        return Column(
          children: [
            // Handle bar
            const SizedBox(height: 12),
            Container(
              width: 38,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 12),

            // Header title
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: const Color(0xFF00BFA5).withOpacity(0.2),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.person_rounded, color: Color(0xFF00BFA5), size: 20),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Kişi Paylaş',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 17,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          'Sohbete eklemek istediğiniz kişiyi seçin',
                          style: TextStyle(color: Colors.white54, fontSize: 11.5),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close_rounded, color: Colors.white70),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 14),

            // Search bar
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Container(
                height: 42,
                decoration: BoxDecoration(
                  color: AppColors.surfaceLight,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: AppColors.cardBorder),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: Row(
                  children: [
                    const Icon(Icons.search_rounded, color: AppColors.primaryLight, size: 20),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TextField(
                        controller: _searchController,
                        style: const TextStyle(color: Colors.white, fontSize: 14),
                        decoration: const InputDecoration(
                          hintText: 'Kişi ismi veya numara ara...',
                          hintStyle: TextStyle(color: Colors.white38, fontSize: 13.5),
                          border: InputBorder.none,
                          isDense: true,
                        ),
                      ),
                    ),
                    if (_searchController.text.isNotEmpty)
                      GestureDetector(
                        onTap: () {
                          _searchController.clear();
                        },
                        child: const Icon(Icons.clear_rounded, color: Colors.white54, size: 18),
                      ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 10),

            // Content list
            Expanded(
              child: _isLoading
                  ? const Center(
                      child: CircularProgressIndicator(color: AppColors.primaryLight),
                    )
                  : !_hasPermission
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(24.0),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.contact_phone_outlined, color: AppColors.callRed, size: 52),
                                const SizedBox(height: 16),
                                const Text(
                                  'Rehber İzni Verilmedi',
                                  style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                                ),
                                const SizedBox(height: 8),
                                const Text(
                                  'Kişi paylaşabilmek için telefon rehberinize erişim izni vermeniz gerekmektedir.',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(color: Colors.white60, fontSize: 13),
                                ),
                                const SizedBox(height: 20),
                                ElevatedButton(
                                  onPressed: _loadContacts,
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: AppColors.primaryLight,
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                  ),
                                  child: const Text('İzin İste', style: TextStyle(color: Colors.white)),
                                ),
                              ],
                            ),
                          ),
                        )
                      : _filteredContacts.isEmpty
                          ? Center(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.search_off_rounded, color: Colors.white.withOpacity(0.3), size: 48),
                                  const SizedBox(height: 12),
                                  Text(
                                    _searchController.text.isEmpty
                                        ? 'Rehberinizde kişi bulunamadı.'
                                        : 'Aramanızla eşleşen kişi bulunamadı.',
                                    style: const TextStyle(color: Colors.white54, fontSize: 13.5),
                                  ),
                                ],
                              ),
                            )
                          : ListView.separated(
                              controller: scrollController,
                              physics: const BouncingScrollPhysics(),
                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                              itemCount: _filteredContacts.length,
                              separatorBuilder: (_, __) => Divider(
                                color: Colors.white.withOpacity(0.04),
                                height: 1,
                              ),
                              itemBuilder: (ctx, index) {
                                final contact = _filteredContacts[index];
                                final phone = contact.phones.isNotEmpty ? contact.phones.first.number : '';
                                final initial = contact.displayName.isNotEmpty
                                    ? contact.displayName.substring(0, 1).toUpperCase()
                                    : '?';

                                return ListTile(
                                  contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                  leading: contact.photo != null
                                      ? CircleAvatar(
                                          radius: 22,
                                          backgroundImage: MemoryImage(contact.photo!),
                                        )
                                      : Container(
                                          width: 44,
                                          height: 44,
                                          decoration: BoxDecoration(
                                            gradient: LinearGradient(
                                              colors: [
                                                const Color(0xFF00BFA5).withOpacity(0.8),
                                                const Color(0xFF00897B),
                                              ],
                                              begin: Alignment.topLeft,
                                              end: Alignment.bottomRight,
                                            ),
                                            shape: BoxShape.circle,
                                          ),
                                          child: Center(
                                            child: Text(
                                              initial,
                                              style: const TextStyle(
                                                color: Colors.white,
                                                fontWeight: FontWeight.bold,
                                                fontSize: 18,
                                              ),
                                            ),
                                          ),
                                        ),
                                  title: Text(
                                    contact.displayName,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 14.5,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  subtitle: Text(
                                    phone,
                                    style: const TextStyle(
                                      color: Colors.white54,
                                      fontSize: 12.5,
                                    ),
                                  ),
                                  trailing: contact.phones.length > 1
                                      ? Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                          decoration: BoxDecoration(
                                            color: Colors.white10,
                                            borderRadius: BorderRadius.circular(10),
                                          ),
                                          child: Text(
                                            '${contact.phones.length} numara',
                                            style: const TextStyle(color: Colors.white70, fontSize: 10),
                                          ),
                                        )
                                      : const Icon(
                                          Icons.arrow_forward_ios_rounded,
                                          color: Colors.white24,
                                          size: 14,
                                        ),
                                  onTap: () => _selectContact(contact),
                                );
                              },
                            ),
            ),
          ],
        );
      },
    );
  }
}
