package main

import (
	"image"
	"image/color"
	"image/draw"
	"image/png"
	"log"
	"math"
	"os"
)

func main() {
	const size = 512
	img := image.NewRGBA(image.Rect(0, 0, size, size))
	draw.Draw(img, img.Bounds(), &image.Uniform{C: color.RGBA{31, 41, 55, 255}}, image.Point{}, draw.Src)

	drawRoundedRect(img, 64, 64, 448, 448, 48, color.RGBA{17, 24, 39, 255})
	drawRoundedRect(img, 190, 82, 322, 334, 66, color.RGBA{249, 250, 251, 255})
	drawRoundedRect(img, 224, 116, 288, 300, 32, color.RGBA{96, 165, 250, 255})
	drawRoundedRect(img, 136, 236, 172, 286, 18, color.RGBA{96, 165, 250, 255})
	drawRoundedRect(img, 340, 236, 376, 286, 18, color.RGBA{96, 165, 250, 255})
	drawRoundedRect(img, 238, 360, 274, 430, 18, color.RGBA{96, 165, 250, 255})
	drawRoundedRect(img, 176, 422, 336, 458, 18, color.RGBA{96, 165, 250, 255})
	drawArc(img, 154, 238, 358, 382, 16, color.RGBA{96, 165, 250, 255})

	file, err := os.Create("Icon.png")
	if err != nil {
		log.Fatal(err)
	}
	defer file.Close()
	if err := png.Encode(file, img); err != nil {
		log.Fatal(err)
	}
}

func drawRoundedRect(img *image.RGBA, x0, y0, x1, y1, r int, c color.RGBA) {
	for y := y0; y < y1; y++ {
		for x := x0; x < x1; x++ {
			dx := max(max(x0+r-x, 0), max(x-(x1-r-1), 0))
			dy := max(max(y0+r-y, 0), max(y-(y1-r-1), 0))
			if dx*dx+dy*dy <= r*r {
				img.SetRGBA(x, y, c)
			}
		}
	}
}

func drawArc(img *image.RGBA, x0, y0, x1, y1, thickness int, c color.RGBA) {
	cx := float64(x0+x1) / 2
	cy := float64(y0+y1) / 2
	rx := float64(x1-x0) / 2
	ry := float64(y1-y0) / 2
	for y := y0; y < y1; y++ {
		for x := x0; x < x1; x++ {
			nx := (float64(x) - cx) / rx
			ny := (float64(y) - cy) / ry
			d := math.Sqrt(nx*nx + ny*ny)
			if d > 0.82 && d < 1.0 && y > 258 {
				img.SetRGBA(x, y, c)
			}
		}
	}
}
