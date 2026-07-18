import MapKit
import SwiftUI
import UIKit

/// A fixed-style MapKit presentation for an ordered cruise itinerary.
///
/// Stops appear immediately. Offline route planning then replaces their input
/// coordinates with normalized water placements and adds each successful leg.
@MainActor
public struct MaritimeRouteMap: View {
  private let stops: [MaritimeRouteStop]

  public init(stops: [MaritimeRouteStop]) {
    self.stops = stops
  }

  public var body: some View {
    MaritimeMapRepresentable(stops: stops)
      .accessibilityIdentifier("MaritimeRouteMap")
  }
}

@MainActor
private struct MaritimeMapRepresentable: UIViewRepresentable {
  let stops: [MaritimeRouteStop]

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  func makeUIView(context: Context) -> MKMapView {
    let mapView = MKMapView(frame: .zero)
    mapView.delegate = context.coordinator
    mapView.mapType = .mutedStandard
    mapView.pointOfInterestFilter = .excludingAll
    mapView.showsCompass = false
    mapView.showsScale = false
    mapView.showsUserLocation = false
    mapView.isPitchEnabled = false
    mapView.isRotateEnabled = false
    mapView.isScrollEnabled = true
    mapView.isZoomEnabled = true
    mapView.register(
      PortAnnotationView.self,
      forAnnotationViewWithReuseIdentifier: PortAnnotationView.reuseIdentifier)
    mapView.register(
      ArrowAnnotationView.self,
      forAnnotationViewWithReuseIdentifier: ArrowAnnotationView.reuseIdentifier)
    context.coordinator.update(stops: stops, on: mapView)
    return mapView
  }

  func updateUIView(_ mapView: MKMapView, context: Context) {
    context.coordinator.update(stops: stops, on: mapView)
  }

  static func dismantleUIView(_ mapView: MKMapView, coordinator: Coordinator) {
    coordinator.cancel()
    mapView.delegate = nil
  }

  @MainActor
  final class Coordinator: NSObject, MKMapViewDelegate {
    private let planner = MaritimeRoutePlanner()
    private var routeTask: Task<Void, Never>?
    private var currentStops: [MaritimeRouteStop] = []

    func update(stops: [MaritimeRouteStop], on mapView: MKMapView) {
      guard stops != currentStops else { return }
      currentStops = stops
      routeTask?.cancel()
      showInitialStops(stops, on: mapView)

      routeTask = Task { [weak self, weak mapView] in
        guard let self else { return }
        let result = await planner.plan(stops: stops)
        guard !Task.isCancelled, self.currentStops == stops, let mapView else { return }
        self.show(result: result, on: mapView)
      }
    }

    func cancel() {
      routeTask?.cancel()
    }

    private func showInitialStops(_ stops: [MaritimeRouteStop], on mapView: MKMapView) {
      mapView.removeOverlays(mapView.overlays)
      mapView.removeAnnotations(mapView.annotations)
      let annotations = stops.compactMap { stop -> PortAnnotation? in
        guard MaritimeGeometry.isValid(stop.coordinate) else { return nil }
        return PortAnnotation(stopID: stop.id, name: stop.title, coordinate: stop.coordinate)
      }
      mapView.addAnnotations(annotations)
      MapViewport.fit(annotations.map(\.maritimeCoordinate), on: mapView, animated: false)
    }

    private func show(result: MaritimeRouteResult, on mapView: MKMapView) {
      mapView.removeOverlays(mapView.overlays)
      mapView.removeAnnotations(mapView.annotations)
      let presentation = MaritimeMapPresentation(result: result)
      let ports = result.placements.compactMap { placement -> PortAnnotation? in
        guard let coordinate = placement.normalizedCoordinate else { return nil }
        return PortAnnotation(
          stopID: placement.stop.id, name: placement.stop.title, coordinate: coordinate)
      }
      mapView.addAnnotations(ports)

      for part in presentation.routeParts where part.count > 1 {
        var coordinates = part.map(\.clLocationCoordinate)
        mapView.addOverlay(
          MKPolyline(coordinates: &coordinates, count: coordinates.count), level: .aboveRoads)
      }
      let arrows = presentation.arrows.map {
        ArrowAnnotation(coordinate: $0.coordinate, angle: $0.angle)
      }
      mapView.addAnnotations(arrows)
      MapViewport.fit(presentation.allCoordinates, on: mapView, animated: true)
    }

    func mapView(_ mapView: MKMapView, viewFor annotation: any MKAnnotation) -> MKAnnotationView? {
      switch annotation {
      case let port as PortAnnotation:
        let view =
          mapView.dequeueReusableAnnotationView(
            withIdentifier: PortAnnotationView.reuseIdentifier,
            for: port
          ) as! PortAnnotationView
        view.configure(name: port.name)
        return view
      case let arrow as ArrowAnnotation:
        let view =
          mapView.dequeueReusableAnnotationView(
            withIdentifier: ArrowAnnotationView.reuseIdentifier,
            for: arrow
          ) as! ArrowAnnotationView
        view.configure(angle: arrow.angle)
        return view
      default:
        return nil
      }
    }

    func mapView(_ mapView: MKMapView, rendererFor overlay: any MKOverlay) -> MKOverlayRenderer {
      guard let polyline = overlay as? MKPolyline else {
        return MKOverlayRenderer(overlay: overlay)
      }
      let renderer = MKPolylineRenderer(polyline: polyline)
      renderer.strokeColor = UIColor(red: 0.035, green: 0.08, blue: 0.12, alpha: 0.96)
      renderer.lineWidth = 2
      renderer.lineCap = .round
      renderer.lineJoin = .round
      return renderer
    }

    func mapView(_ mapView: MKMapView, didSelect annotation: any MKAnnotation) {
      mapView.deselectAnnotation(annotation, animated: false)
    }
  }
}

private final class PortAnnotation: NSObject, MKAnnotation {
  let stopID: String
  let name: String
  dynamic var coordinate: CLLocationCoordinate2D

  var maritimeCoordinate: MaritimeCoordinate {
    MaritimeCoordinate(latitude: coordinate.latitude, longitude: coordinate.longitude)
  }

  init(stopID: String, name: String, coordinate: MaritimeCoordinate) {
    self.stopID = stopID
    self.name = name
    self.coordinate = coordinate.clLocationCoordinate
  }
}

private final class ArrowAnnotation: NSObject, MKAnnotation {
  dynamic var coordinate: CLLocationCoordinate2D
  let angle: CGFloat

  init(coordinate: MaritimeCoordinate, angle: CGFloat) {
    self.coordinate = coordinate.clLocationCoordinate
    self.angle = angle
  }
}

@MainActor
private final class PortAnnotationView: MKAnnotationView {
  static let reuseIdentifier = "MaritimeRoutePort"
  private let nameLabel = UILabel()
  private let dot = UIView()

  override init(annotation: (any MKAnnotation)?, reuseIdentifier: String?) {
    super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
    frame = CGRect(x: 0, y: 0, width: 180, height: 42)
    centerOffset = CGPoint(x: 0, y: -17)
    collisionMode = .none
    displayPriority = .required
    canShowCallout = false
    isEnabled = false

    nameLabel.translatesAutoresizingMaskIntoConstraints = false
    nameLabel.font = .systemFont(ofSize: 12, weight: .semibold)
    nameLabel.textColor = UIColor(red: 0.035, green: 0.08, blue: 0.12, alpha: 1)
    nameLabel.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.84)
    nameLabel.textAlignment = .center
    nameLabel.layer.cornerRadius = 6
    nameLabel.layer.masksToBounds = true
    addSubview(nameLabel)

    dot.translatesAutoresizingMaskIntoConstraints = false
    dot.backgroundColor = UIColor(red: 0.035, green: 0.08, blue: 0.12, alpha: 1)
    dot.layer.cornerRadius = 5
    addSubview(dot)

    NSLayoutConstraint.activate([
      nameLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
      nameLabel.topAnchor.constraint(equalTo: topAnchor),
      nameLabel.heightAnchor.constraint(equalToConstant: 24),
      nameLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 176),
      nameLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 48),
      dot.centerXAnchor.constraint(equalTo: centerXAnchor),
      dot.bottomAnchor.constraint(equalTo: bottomAnchor),
      dot.widthAnchor.constraint(equalToConstant: 10),
      dot.heightAnchor.constraint(equalToConstant: 10),
    ])
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func configure(name: String) {
    nameLabel.text = "  \(name)  "
    accessibilityLabel = name
  }
}

@MainActor
private final class ArrowAnnotationView: MKAnnotationView {
  static let reuseIdentifier = "MaritimeRouteArrow"
  private let arrowLayer = CAShapeLayer()

  override init(annotation: (any MKAnnotation)?, reuseIdentifier: String?) {
    super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
    frame = CGRect(x: 0, y: 0, width: 24, height: 24)
    centerOffset = .zero
    collisionMode = .none
    displayPriority = .required
    canShowCallout = false
    isEnabled = false
    let path = UIBezierPath()
    path.move(to: CGPoint(x: 3, y: 8))
    path.addLine(to: CGPoint(x: 18, y: 8))
    path.addLine(to: CGPoint(x: 18, y: 4))
    path.addLine(to: CGPoint(x: 23, y: 12))
    path.addLine(to: CGPoint(x: 18, y: 20))
    path.addLine(to: CGPoint(x: 18, y: 16))
    path.addLine(to: CGPoint(x: 3, y: 16))
    path.close()
    arrowLayer.path = path.cgPath
    arrowLayer.fillColor = UIColor(red: 0.035, green: 0.08, blue: 0.12, alpha: 0.96).cgColor
    layer.addSublayer(arrowLayer)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    transform = .identity
  }

  func configure(angle: CGFloat) {
    transform = CGAffineTransform(rotationAngle: angle)
    accessibilityLabel = "Route direction"
  }
}

struct MaritimeMapPresentation {
  struct Arrow {
    let coordinate: MaritimeCoordinate
    let angle: CGFloat
  }

  let routeParts: [[MaritimeCoordinate]]
  let arrows: [Arrow]
  let allCoordinates: [MaritimeCoordinate]

  init(result: MaritimeRouteResult) {
    routeParts = result.legs.flatMap { MaritimeGeometry.splitAtAntimeridian($0.coordinates) }
    arrows = result.legs.compactMap { leg in
      MaritimeGeometry.arrow(for: leg.coordinates).map(Arrow.init)
    }
    allCoordinates =
      result.placements.compactMap(\.normalizedCoordinate)
      + result.legs.flatMap(\.coordinates)
  }
}

enum MapViewport {
  @MainActor
  static func fit(_ coordinates: [MaritimeCoordinate], on mapView: MKMapView, animated: Bool) {
    guard let region = region(for: coordinates) else { return }
    mapView.setRegion(region, animated: animated)
  }

  static func region(for coordinates: [MaritimeCoordinate]) -> MKCoordinateRegion? {
    guard !coordinates.isEmpty else { return nil }
    let latitudes = coordinates.map(\.latitude)
    let minLatitude = latitudes.min()!
    let maxLatitude = latitudes.max()!
    let normalizedLongitudes = coordinates.map {
      ($0.longitude + 360).truncatingRemainder(dividingBy: 360)
    }.sorted()
    var largestGap = -1.0
    var arcStart = normalizedLongitudes[0]
    for index in normalizedLongitudes.indices {
      let current = normalizedLongitudes[index]
      let next =
        index == normalizedLongitudes.count - 1
        ? normalizedLongitudes[0] + 360
        : normalizedLongitudes[index + 1]
      let gap = next - current
      if gap > largestGap {
        largestGap = gap
        arcStart = next.truncatingRemainder(dividingBy: 360)
      }
    }
    let longitudeSpan = min(360, max(0.08, (360 - largestGap) * 1.28))
    let latitudeSpan = min(170, max(0.08, (maxLatitude - minLatitude) * 1.35))
    let centerLongitude = MaritimeGeometry.normalizeLongitude(arcStart + (360 - largestGap) / 2)
    return MKCoordinateRegion(
      center: CLLocationCoordinate2D(
        latitude: (minLatitude + maxLatitude) / 2,
        longitude: centerLongitude
      ),
      span: MKCoordinateSpan(latitudeDelta: latitudeSpan, longitudeDelta: longitudeSpan)
    )
  }
}

extension MaritimeCoordinate {
  fileprivate var clLocationCoordinate: CLLocationCoordinate2D {
    CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
  }
}
