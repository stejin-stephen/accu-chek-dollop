import 'dart:async'; // Required for Future.delayed
import 'dart:io';
import 'dart:math'; // Required for pow()

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'HelixStream Scanner',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blueAccent),
        useMaterial3: true,
      ),
      home: const ScannerPage(),
    );
  }
}

class ScannerPage extends StatefulWidget {
  const ScannerPage({super.key});

  @override
  State<ScannerPage> createState() => _ScannerPageState();
}

class _ScannerPageState extends State<ScannerPage> {
  final List<ScanResult> _scanResults = [];
  BluetoothDevice? _connectedDevice;
  String? _glucoseReading;
  String _status = 'Idle. Ready to scan.';

  // Standard BLE UUIDs for Glucose
  final String _glucoseServiceUuid = "00001808-0000-1000-8000-00805f9b34fb";
  final String _glucoseMeasurementCharUuid = "00002a18-0000-1000-8000-00805f9b34fb";
  final String _racpCharUuid = "00002a52-0000-1000-8000-00805f9b34fb"; // Record Access Control Point

  @override
  void initState() {
    super.initState();
  }

  // 1. Permissions Logic
  Future<bool> _checkPermissions() async {
    if (Platform.isAndroid) {
      Map<Permission, PermissionStatus> statuses = await [
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
        Permission.location,
      ].request();

      if (statuses[Permission.bluetoothScan]!.isDenied ||
          statuses[Permission.bluetoothConnect]!.isDenied) {
        return false;
      }
    }
    return true;
  }

  // 2. Scan Logic with 30s Timeout
  Future<void> _startScan() async {
    bool permissionsGranted = await _checkPermissions();
    if (!permissionsGranted) {
      setState(() => _status = 'Permissions denied. Check Settings.');
      return;
    }

    setState(() {
      _scanResults.clear();
      _status = 'STEP 1: Hold Accu-Chek button for 3 sec until Bluetooth icon flashes.';
      _glucoseReading = null;
    });

    // Listen to results
    var subscription = FlutterBluePlus.onScanResults.listen((results) {
      setState(() {
        _scanResults.clear();
        _scanResults.addAll(results);
      });
    });

    FlutterBluePlus.cancelWhenScanComplete(subscription);

    try {
      await FlutterBluePlus.startScan(
        timeout: const Duration(seconds: 30), // Extended for manual wake-up
        withServices: [Guid(_glucoseServiceUuid)], // Filter for Glucose devices
        androidUsesFineLocation: true,
      );
    } catch (e) {
      setState(() => _status = "Scan Error: $e");
    }

    // Wait for scan to finish
    await FlutterBluePlus.isScanning.where((val) => val == false).first;
  }

  // 3. Simplified Connection Logic (Lazy Bonding)
  Future<void> _connectAndListen(ScanResult result) async {
    final device = result.device;
    setState(() => _status = 'Connecting to ${device.platformName}...');

    try {
      await FlutterBluePlus.stopScan();

      // A. Connect (Wait for stability)
      await device.connect(autoConnect: false);
      setState(() => _status = 'Stabilizing Connection...');
      await Future.delayed(const Duration(seconds: 1));

      // B. Discover Services (This may fail if not paired, but usually Android handles it)
      setState(() => _status = 'Discovering Services...');
      List<BluetoothService> services = await device.discoverServices();

      BluetoothCharacteristic? measureChar;
      BluetoothCharacteristic? racpChar;

      // Locate the Characteristics
      for (var service in services) {
        if (service.uuid.toString() == _glucoseServiceUuid) {
          for (var c in service.characteristics) {
            if (c.uuid.toString() == _glucoseMeasurementCharUuid) {
              measureChar = c;
            }
            if (c.uuid.toString() == _racpCharUuid) {
              racpChar = c;
            }
          }
        }
      }

      if (measureChar != null) {
        // C. Enable Notifications (This triggers Pairing Popup on Android!)
        await measureChar.setNotifyValue(true);
        final subscription = measureChar.lastValueStream.listen((data) {
          if (data.isNotEmpty) _decodeGlucosePacket(data);
        });
        device.cancelWhenDisconnected(subscription);
        setState(() => _status = 'Connected! Waiting for data...');
      }

      // D. Trigger History Sync (Required for Accu-Chek Instant)
      if (racpChar != null) {
        setState(() => _status = 'Requesting stored records...');
        await racpChar.setNotifyValue(true);

        // Command: Report Stored Records (OpCode 1) -> All Records (Operator 1)
        // [0x01, 0x01]
        await racpChar.write([0x01, 0x01]);
        print("📥 RACP Command Sent: Report All History");
      }

    } catch (e) {
      setState(() => _status = 'Connection Error: $e');
      // Force disconnect to reset state
      await device.disconnect();
    }
  }

  // 4. Corrected Parsing Logic (IEEE-11073 SFLOAT)
  void _decodeGlucosePacket(List<int> data) {
    if (data.length < 10) return;

    final flags = data[0];
    final timeOffsetPresent = (flags & 0x01) > 0;
    final concentrationUnitKgL = (flags & 0x04) > 0; // 0 = kg/L, 1 = mol/L

    // Calculate Index
    int valueIndex = 10;
    if (timeOffsetPresent) valueIndex += 2;

    if (data.length < valueIndex + 2) return;

    // Parse SFLOAT
    int b0 = data[valueIndex];
    int b1 = data[valueIndex + 1];
    int sfloat = (b1 << 8) + b0;

    int mantissa = sfloat & 0x0FFF;
    int exponent = sfloat >> 12;

    if (mantissa >= 0x0800) mantissa = -((0x1000 - mantissa));
    if (exponent >= 0x08) exponent = -((0x10 - exponent));

    double value = (mantissa * pow(10, exponent)).toDouble();

    // Unit Conversion
    if (!concentrationUnitKgL) {
      value = value * 100000; // kg/L -> mg/dL
    } else {
      value = value * 18;     // mol/L -> mg/dL
    }

    setState(() {
      _glucoseReading = "${value.toStringAsFixed(0)} mg/dL";
      _status = "✅ Data Received!";
    });
  }

  Future<void> _disconnect() async {
    if (_connectedDevice != null) {
      await _connectedDevice!.disconnect();
    }
    if (mounted) {
      setState(() {
        _connectedDevice = null;
        _status = 'Disconnected';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('HelixStream PoC')),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            Text(_status, textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 20),
            if (_glucoseReading != null)
              Text(_glucoseReading!, style: const TextStyle(fontSize: 40, color: Colors.green, fontWeight: FontWeight.bold)),
            const SizedBox(height: 20),

            // Reactive Scan Button
            StreamBuilder<bool>(
              stream: FlutterBluePlus.isScanning,
              initialData: false,
              builder: (c, snapshot) {
                if (snapshot.data ?? false) {
                  return const CircularProgressIndicator();
                } else {
                  return ElevatedButton(
                    onPressed: _startScan,
                    child: const Text('SCAN (Hold Button 3s)'),
                  );
                }
              },
            ),

            const SizedBox(height: 20),
            Expanded(
              child: ListView.builder(
                itemCount: _scanResults.length,
                itemBuilder: (c, i) {
                  final r = _scanResults[i];
                  return ListTile(
                    title: Text(r.device.platformName.isNotEmpty ? r.device.platformName : "Unknown Device"),
                    subtitle: Text(r.device.remoteId.toString()),
                    trailing: const Icon(Icons.bluetooth),
                    onTap: () => _connectAndListen(r),
                  );
                },
              ),
            ),
            if (_connectedDevice != null)
              ElevatedButton(onPressed: _disconnect, child: const Text("Disconnect")),
          ],
        ),
      ),
    );
  }
}