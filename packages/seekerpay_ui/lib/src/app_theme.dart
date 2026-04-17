import 'package:flutter/material.dart';

/// Centralised colour palette for the SeekerPay UI.
///
/// Uses a pure monochromatic dark base with vibrant accent colours for icons.
class AppColors {
  // Pure Monochromatic Theme
  static const Color background = Color(0xFF000000); // Absolute Black
  static const Color surface = Color(0xFF121212); // Near Black Surface
  static const Color card = Color(0xFF1C1C1E); // Dark Grey Card
  
  // High Contrast Accents
  static const Color primary = Color(0xFFFFFFFF); // Pure White
  static const Color accent = Color(0xFFF2F2F7); // Off White
  static const Color error = Color(0xFFFF453A); // Keep red for errors (standard)
  
  static const Color text = Color(0xFFFFFFFF); // White text
  static const Color textSecondary = Color(0xFF8E8E93); // Grey text
  static const Color textDisabled = Color(0xFF444446); // Dark grey text

  // Vibrant Accents for Icons
  static const Color purple = Color(0xFFBF5AF2);
  static const Color green = Color(0xFF32D74B);
  static const Color blue = Color(0xFF0A84FF);
  static const Color orange = Color(0xFFFF9F0A);
  static const Color pink = Color(0xFFFF375F);
}

/// Predefined [LinearGradient] values used across the SeekerPay UI.
class AppGradients {
  // Monochromatic Gradients
  static const LinearGradient primary = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [
      Color(0xFFFFFFFF),
      Color(0xFFC7C7CC),
    ],
  );

  static const LinearGradient surface = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [
      Color(0xFF1C1C1E),
      Color(0xFF000000),
    ],
  );

  static const LinearGradient glass = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [
      Colors.white10,
      Colors.transparent,
    ],
  );
}

/// Factory for the SeekerPay [ThemeData] configurations.
class AppTheme {
  /// The primary dark [ThemeData] using Material 3 with [AppColors] and [AppGradients].
  static ThemeData get darkTheme => ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    primaryColor: AppColors.primary,
    scaffoldBackgroundColor: AppColors.background,
    
    colorScheme: const ColorScheme.dark(
      primary: AppColors.primary,
      secondary: AppColors.primary,
      surface: AppColors.surface,
      error: AppColors.error,
      onPrimary: Colors.black,
      onSurface: AppColors.text,
    ),
    
    appBarTheme: const AppBarTheme(
      backgroundColor: Colors.transparent,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        fontSize: 20,
        fontWeight: FontWeight.w900,
        color: AppColors.text,
        letterSpacing: 1,
      ),
      iconTheme: IconThemeData(color: AppColors.primary),
    ),

    cardTheme: CardThemeData(
      color: AppColors.card,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(24),
        side: const BorderSide(color: Colors.white10),
      ),
    ),

    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.black,
        elevation: 0,
        textStyle: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16, letterSpacing: 1),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 24),
      ),
    ),

    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AppColors.surface,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(18),
        borderSide: const BorderSide(color: Colors.white10),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(18),
        borderSide: const BorderSide(color: Colors.white10),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(18),
        borderSide: const BorderSide(color: AppColors.primary, width: 1.5),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
      hintStyle: const TextStyle(color: AppColors.textDisabled),
    ),

    bottomNavigationBarTheme: const BottomNavigationBarThemeData(
      backgroundColor: Colors.black,
      selectedItemColor: AppColors.primary,
      unselectedItemColor: AppColors.textSecondary,
      type: BottomNavigationBarType.fixed,
      elevation: 0,
    ),
  );
}
