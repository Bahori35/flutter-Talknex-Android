class AiWeatherModel {
  final String location;
  final int temp;
  final int feelsLike;
  final int humidity;
  final int windSpeed;
  final String description;
  final String icon;
  final int? maxTemp;
  final int? minTemp;

  AiWeatherModel({
    required this.location,
    required this.temp,
    required this.feelsLike,
    required this.humidity,
    required this.windSpeed,
    required this.description,
    required this.icon,
    this.maxTemp,
    this.minTemp,
  });

  Map<String, dynamic> toJson() => {
    'location': location,
    'temp': temp,
    'feelsLike': feelsLike,
    'humidity': humidity,
    'windSpeed': windSpeed,
    'description': description,
    'icon': icon,
    if (maxTemp != null) 'maxTemp': maxTemp,
    if (minTemp != null) 'minTemp': minTemp,
  };

  factory AiWeatherModel.fromJson(Map<String, dynamic> json) => AiWeatherModel(
    location: json['location'] ?? '',
    temp: (json['temp'] as num?)?.toInt() ?? 0,
    feelsLike: (json['feelsLike'] as num?)?.toInt() ?? 0,
    humidity: (json['humidity'] as num?)?.toInt() ?? 0,
    windSpeed: (json['windSpeed'] as num?)?.toInt() ?? 0,
    description: json['description'] ?? '',
    icon: json['icon'] ?? '🌤️',
    maxTemp: (json['maxTemp'] as num?)?.toInt(),
    minTemp: (json['minTemp'] as num?)?.toInt(),
  );
}
