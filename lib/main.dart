import 'dart:io';

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
      title: 'Accu-Chek Instant Scanner',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
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
  bool _isScanning = false;
  BluetoothDevice? _connectedDevice;
  String? _glucoseReading;
  String? _status;

  @override
  void initState() {
    super.initState();
    _status = 'Idle';
  }

  Future<void> _startScan() async {
    // Request permissions
    await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.location,
    ].request();

    setState(() {
      _scanResults.clear();
      _isScanning = true;
      _status = 'Scanning for Accu-Chek Instant...';
      _glucoseReading = null;
    });

    // Check if Bluetooth is enabled, and try to enable it on Android
    if (Platform.isAndroid) {
      try {
        await FlutterBluePlus.turnOn();
      } catch (e) {
        setState(() {
          _status = 'User denied turning on Bluetooth';
          _isScanning = false;
        });
        return;
      }
    }

    // Wait for Bluetooth to be on
    // This handles both the successful turnOn case and if it was already on
    try {
      await FlutterBluePlus.adapterState
          .where((s) => s == BluetoothAdapterState.on)
          .first
          .timeout(const Duration(seconds: 5));
    } catch (e) {
      setState(() {
        _status = 'Bluetooth is not enabled';
        _isScanning = false;
      });
      return;
    }

    // Listen to scan results and keep only Accu-Chek Instant devices
    final subscription = FlutterBluePlus.onScanResults.listen((results) {
      final filtered = results.where((r) {
        final name = r.advertisementData.advName.toLowerCase();
        return name.contains('accu-chek instant') ||
            name.contains('accu-chek') ||
            name.contains('accu chek');
      }).toList();

      if (filtered.isEmpty) return;

      setState(() {
        _scanResults
          ..clear()
          ..addAll(filtered);
      });
    }, onError: (e) {
      setState(() {
        _status = 'Scan error: $e';
        _isScanning = false;
      });
    });

    // Ensure subscription is cancelled when scan completes
    FlutterBluePlus.cancelWhenScanComplete(subscription);

    try {
      await FlutterBluePlus.startScan(
        timeout: const Duration(seconds: 10),
        withNames: const ['Accu-Chek Instant'],
        androidScanMode: AndroidScanMode.lowLatency,
        androidUsesFineLocation: true,
      );
    } catch (e) {
      setState(() {
        _status = 'Start scan failed: $e';
        _isScanning = false;
      });
      return;
    }

    setState(() {
      _isScanning = false;
      if (_scanResults.isEmpty) {
        _status = 'No Accu-Chek Instant devices found';
      } else {
        _status = 'Select a device to connect';
      }
    });
  }

  Future<void> _connectAndListen(ScanResult result) async {
    final device = result.device;

    setState(() {
      _status = 'Connecting to ${device.remoteId}...';
      _glucoseReading = null;
    });

    try {
      await FlutterBluePlus.stopScan();

      await device.connect(timeout: const Duration(seconds: 15));
      setState(() {
        _connectedDevice = device;
        _status = 'Discovering services...';
      });

      final services = await device.discoverServices();

      // Standard Glucose service & measurement characteristic UUIDs (0x1808 / 0x2A18)
      const glucoseServiceUuid =
          '00001808-0000-1000-8000-00805f9b34fb';
      const glucoseMeasurementUuid =
          '00002a18-0000-1000-8000-00805f9b34fb';

      BluetoothCharacteristic? measurementCharacteristic;

      for (final service in services) {
        if (service.uuid.toString().toLowerCase() ==
            glucoseServiceUuid) {
          for (final c in service.characteristics) {
            if (c.uuid.toString().toLowerCase() ==
                glucoseMeasurementUuid) {
              measurementCharacteristic = c;
              break;
            }
          }
        }
      }

      if (measurementCharacteristic == null) {
        setState(() {
          _status =
              'Glucose measurement characteristic not found on device';
        });
        await device.disconnect();
        return;
      }

      setState(() {
        _status = 'Subscribed to glucose measurements';
      });

      final subscription =
          measurementCharacteristic.onValueReceived.listen((data) {
        final decoded = _decodeGlucoseMeasurement(data);
        setState(() {
          _glucoseReading = decoded;
          _status = 'Last reading: $decoded';
        });
      }, onError: (e) {
        setState(() {
          _status = 'Error receiving glucose data: $e';
        });
      });

      device.cancelWhenDisconnected(subscription);

      await measurementCharacteristic.setNotifyValue(true);
    } catch (e) {
      setState(() {
        _status = 'Connection error: $e';
      });
      await device.disconnect();
    }
  }

  String _decodeGlucoseMeasurement(List<int> data) {
    if (data.length < 3) {
      return 'Invalid measurement (len=${data.length})';
    }

    // Basic IEEE-11073 16-bit SFLOAT decoding (typical for glucose meters).
    // This may need adjustment based on the exact Accu-Chek Instant spec.
    final flags = data[0];
    // Next two bytes: SFLOAT glucose concentration.
    final value = _decodeSfloat(data[1], data[2]);

    // Flag bit 0 typically indicates units: 0 = kg/L, 1 = mol/L.
    final isMolPerL = (flags & 0x01) != 0;
    if (isMolPerL) {
      // Convert mmol/L to mg/dL for display: 1 mmol/L ≈ 18.01559 mg/dL.
      final mgPerDl = value * 18.01559;
      return '${value.toStringAsFixed(2)} mmol/L (${mgPerDl.toStringAsFixed(0)} mg/dL)';
    } else {
      return '${value.toStringAsFixed(0)} mg/dL';
    }
  }

  double _decodeSfloat(int lowByte, int highByte) {
    final raw = (highByte << 8) | lowByte;

    // IEEE-11073 SFLOAT: 12-bit mantissa, 4-bit exponent (base 10)
    int mantissa = raw & 0x0FFF;
    int exponent = raw >> 12;

    // Sign extend mantissa if needed
    if (mantissa >= 0x0800) {
      mantissa = mantissa - 0x1000;
    }

    // Sign extend exponent if needed
    if (exponent >= 0x0008) {
      exponent = exponent - 0x0010;
    }

    return mantissa * pow10(exponent);
  }

  double pow10(int exponent) {
    if (exponent == 0) return 1.0;
    double result = 1.0;
    if (exponent > 0) {
      for (int i = 0; i < exponent; i++) {
        result *= 10.0;
      }
    } else {
      for (int i = 0; i < -exponent; i++) {
        result /= 10.0;
      }
    }
    return result;
  }

  Future<void> _disconnect() async {
    final device = _connectedDevice;
    if (device == null) return;

    await device.disconnect();
    if (!mounted) return;
    setState(() {
      _connectedDevice = null;
      _status = 'Disconnected';
    });
  }

  @override
  void dispose() {
    FlutterBluePlus.stopScan();
    _disconnect();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Accu-Chek Instant Scanner PoC'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Status: ${_status ?? 'Unknown'}',
              style: Theme.of(context).textTheme.bodyLarge,
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _isScanning ? null : _startScan,
              child: const Text('Scan for Accu-Chek Instant'),
            ),
            const SizedBox(height: 16),
            if (_scanResults.isNotEmpty)
              Expanded(
                child: ListView.builder(
                  itemCount: _scanResults.length,
                  itemBuilder: (context, index) {
                    final result = _scanResults[index];
                    final name = result.advertisementData.advName.isNotEmpty
                        ? result.advertisementData.advName
                        : '(unnamed)';
                    return ListTile(
                      title: Text(name),
                      subtitle:
                          Text('ID: ${result.device.remoteId} RSSI: ${result.rssi}'),
                      onTap: () => _connectAndListen(result),
                    );
                  },
                ),
              ),
            if (_glucoseReading != null) ...[
              const SizedBox(height: 16),
              Text(
                'Decoded glucose reading:',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              Text(
                _glucoseReading!,
                style: Theme.of(context)
                    .textTheme
                    .headlineMedium
                    ?.copyWith(color: Colors.deepPurple),
              ),
            ],
            const SizedBox(height: 16),
            if (_connectedDevice != null)
              ElevatedButton(
                onPressed: _disconnect,
                child: const Text('Disconnect'),
              ),
          ],
        ),
      ),
    );
  }
}
